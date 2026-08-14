import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/network/dio_client.dart';
import '../entities/source_subscription.dart';
import '../entities/book_source.dart';
import '../../data/models/source_subscription_model.dart';
import '../repositories/book_source_repository.dart';

/// 订阅内容解析失败（格式错误/内容为空/条目无效），消息即用户可见文案。
/// 与"解析成功但为空"区分：前者抛异常写入"更新失败"，后者返回空列表。
class SubscriptionParseException implements Exception {
  final String message;
  const SubscriptionParseException(this.message);

  @override
  String toString() => message;
}

/// 订阅下载失败（大小超限/地址无效/下载超时等），消息即用户可见文案
class SubscriptionDownloadException implements Exception {
  final String message;
  const SubscriptionDownloadException(this.message);

  @override
  String toString() => message;
}

/// 书源订阅管理
class ManageSubscription {
  final BookSourceRepository bookSourceRepository;
  final DioClient _client;

  ManageSubscription({
    required this.bookSourceRepository,
    DioClient? client,
  }) : _client = client ?? DioClient();

  static const String _boxName = 'source_subscriptions';

  /// 订阅内容大小上限（与网络导入一致），防止异常大文件拖垮内存
  static const int maxSubscriptionBytes = 50 * 1024 * 1024;

  /// 批量更新时的最大并发下载数
  static const int maxConcurrentUpdates = 2;

  /// 订阅下载总时限兜底（进度模式无固定 receiveTimeout，超时防挂起）
  static const Duration _feedTotalTimeout = Duration(minutes: 2);

  Box<SourceSubscriptionModel>? _cachedBox;

  Future<Box<SourceSubscriptionModel>> _box() async =>
      // 订阅盒含凭据：必须走加密打开（initHive 已打开实例会复用）
    _cachedBox ??= await openSensitiveBox<SourceSubscriptionModel>(_boxName);

  Future<List<SourceSubscription>> getAll() async {
    final box = await _box();
    return box.values.map((e) => e.toEntity()).toList();
  }

  Future<void> add(String name, String url) async {
    final box = await _box();
    final sub = SourceSubscriptionModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
    );
    await box.put(sub.id, sub);
  }

  Future<void> remove(String id) async {
    final box = await _box();
    await box.delete(id);
  }

  /// 更新单个订阅。下载受 50MB 上限约束且禁用自动重试；解析失败写入"更新失败"，
  /// 解析成功但为空写入"成功更新 0 个书源"（与失败区分）。
  Future<int> updateSubscription(
    SourceSubscription subscription, {
    CancelToken? cancelToken,
  }) async {
    try {
      final content = await _fetchFeed(subscription.url, cancelToken: cancelToken);
      final sources = _parseContent(content);

      for (final source in sources) {
        await bookSourceRepository.save(await _mergeLocalPreference(source));
      }

      // 更新订阅状态
      final box = await _box();
      final model = SourceSubscriptionModel.fromEntity(
        subscription.copyWith(
          lastUpdatedAt: DateTime.now(),
          lastUpdateResult: '成功更新 ${sources.length} 个书源',
        ),
      );
      await box.put(subscription.id, model);

      return sources.length;
    } on DioException catch (e) {
      // 用户主动取消：不落库失败状态（保留原有 lastUpdateResult），
      // 否则 UI 会显示"更新失败: 已取消"，用户视角像真的失败。
      if (e.type == DioExceptionType.cancel &&
          (cancelToken?.isCancelled ?? false)) {
        return 0;
      }
      final box = await _box();
      final model = SourceSubscriptionModel.fromEntity(
        subscription.copyWith(
          lastUpdateResult: '更新失败: ${_friendlyError(e)}',
        ),
      );
      await box.put(subscription.id, model);
      return 0;
    } catch (e) {
      final box = await _box();
      final model = SourceSubscriptionModel.fromEntity(
        subscription.copyWith(
          lastUpdateResult: '更新失败: ${_friendlyError(e)}',
        ),
      );
      await box.put(subscription.id, model);
      return 0;
    }
  }

  /// 保存前合并用户本地偏好：保留本地启用状态；feed 未提供 cookie 时保留本地登录态，
  /// 避免更新把用户禁用状态与登录态冲掉。
  Future<BookSource> _mergeLocalPreference(BookSource source) async {
    final local = await bookSourceRepository.getById(source.id);
    if (local == null) return source;
    final mergedRules = Map<String, dynamic>.from(source.rules);
    if (!source.rules.containsKey('cookie') && local.rules.containsKey('cookie')) {
      mergedRules['cookie'] = local.rules['cookie'];
    }
    return source.copyWith(enabled: local.enabled, rules: mergedRules);
  }

  /// 异常转友好提示，避免将服务器细节持久化展示
  static String _friendlyError(Object error) {
    if (error is SubscriptionParseException || error is SubscriptionDownloadException) {
      return error.toString();
    }
    if (error is ArgumentError) return '地址无效';
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '连接超时';
        case DioExceptionType.connectionError:
          return '无法连接服务器';
        case DioExceptionType.badResponse:
          return '服务器响应异常';
        case DioExceptionType.cancel:
          return '已取消';
        default:
          return '请求失败';
      }
    }
    return '未知错误';
  }

  /// 更新所有订阅：受限并发（最多 [maxConcurrentUpdates] 个同时下载），
  /// 支持取消与逐条进度回调（completed/total）。
  Future<int> updateAll({
    CancelToken? cancelToken,
    void Function(int completed, int total)? onProgress,
  }) async {
    final subs = await getAll();
    if (subs.isEmpty) return 0;

    var total = 0;
    var completed = 0;
    var nextIndex = 0;

    Future<void> worker() async {
      while (!(cancelToken?.isCancelled ?? false)) {
        final index = nextIndex++;
        if (index >= subs.length) break;
        total += await updateSubscription(subs[index], cancelToken: cancelToken);
        completed++;
        onProgress?.call(completed, subs.length);
      }
    }

    await Future.wait(List.generate(maxConcurrentUpdates, (_) => worker()));
    return total;
  }

  /// 下载订阅内容：限制响应体 ≤ [maxSubscriptionBytes]、禁用自动重试
  /// （避免长任务被重试放大数倍时长）、支持取消。
  /// 经 DioClient.getStringWithProgress 发起：复用其 SSRF 私网 IP 校验、
  /// 重定向安全处理（禁 HTTPS 降级、跨域清敏感头、上限 5 跳）与 UA/限频拦截器。
  Future<String> _fetchFeed(String url, {CancelToken? cancelToken}) async {
    final internalToken = CancelToken();
    cancelToken?.whenCancel.then((_) => internalToken.cancel());
    var sizeExceeded = false;
    // receiveTimeout 为零（进度模式），总时限兜底防挂起
    final totalTimer = Timer(_feedTotalTimeout, () {
      if (!internalToken.isCancelled) internalToken.cancel();
    });
    try {
      final content = await _client.getStringWithProgress(
        url,
        extra: {'no_retry': true},
        onProgress: (received, total) {
          if (received > maxSubscriptionBytes) {
            sizeExceeded = true;
            internalToken.cancel();
          }
        },
        cancelToken: internalToken,
      );
      if (sizeExceeded) {
        throw const SubscriptionDownloadException('订阅内容超过大小限制');
      }
      return content;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        if (sizeExceeded) {
          throw const SubscriptionDownloadException('订阅内容超过大小限制');
        }
        if (cancelToken?.isCancelled ?? false) rethrow;
        throw const SubscriptionDownloadException('下载超时');
      }
      throw SubscriptionDownloadException('下载失败: ${_friendlyError(e)}');
    } finally {
      totalTimer.cancel();
    }
  }

  /// 解析订阅内容（书源对象或数组）。
  /// 格式错误抛 [SubscriptionParseException]；解析成功但无有效书源返回空列表（区别于失败）。
  List<BookSource> _parseContent(String content) {
    final text = content.trim();
    if (text.isEmpty) {
      throw const SubscriptionParseException('订阅内容为空');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const SubscriptionParseException('订阅内容不是有效的 JSON');
    }
    if (decoded is List) {
      final sources = <BookSource>[];
      for (final item in decoded) {
        // 逐条容错：非对象条目跳过，不因单个坏条目放弃整批
        if (item is! Map) continue;
        final source = _parseBookSource(Map<String, dynamic>.from(item));
        if (source != null) sources.add(source);
      }
      return sources;
    }
    if (decoded is Map) {
      final source = _parseBookSource(Map<String, dynamic>.from(decoded));
      if (source == null) {
        throw const SubscriptionParseException('订阅内容格式错误');
      }
      return [source];
    }
    throw const SubscriptionParseException('订阅内容格式错误');
  }

  /// 单条书源解析；既无名称也无地址的条目视为无效数据返回 null
  BookSource? _parseBookSource(Map<String, dynamic> map) {
    final name = map['bookSourceName']?.toString().trim() ?? '';
    final url = map['bookSourceUrl']?.toString().trim() ?? '';
    if (name.isEmpty && url.isEmpty) return null;

    final rules = Map<String, dynamic>.from(map);
    rules.remove('bookSourceName');
    rules.remove('bookSourceGroup');
    rules.remove('bookSourceUrl');
    rules.remove('enabled');

    return BookSource(
      // 无 bookSourceUrl 时基于名称生成稳定 id：同一订阅反复更新合并为同一书源，
      // 避免每次更新生成随机 id 导致重复书源无限累积
      id: url.isNotEmpty ? url : _stableIdFromName(name),
      name: name.isEmpty ? '未命名书源' : name,
      bookSourceUrl: url.isEmpty ? null : url,
      bookSourceGroup: map['bookSourceGroup']?.toString(),
      enabled: BookSource.parseBool(map['enabled']) ?? true,
      rules: rules,
    );
  }

  /// 基于名称的稳定 id：去空白小写名称直接作为 id。
  /// 用名称本身而非哈希，避免 32-bit 哈希碰撞导致不同书源被误合并。
  static String _stableIdFromName(String name) {
    return 'sub:${name.toLowerCase().replaceAll(RegExp(r'\s+'), '')}';
  }
}
