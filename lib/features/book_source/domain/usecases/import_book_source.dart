import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:either_dart/either.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/network/url_redact.dart';
import '../../data/services/source_subscription_store.dart';
import '../entities/book_source.dart';
import '../repositories/book_source_repository.dart';
import 'parse_book_source_rule.dart';

/// 导入受限制（文件超限/下载超时）时抛出的专用异常，消息即用户可见文案。
/// 与普通网络失败区分：超限/超时给出明确提示，不再伪装成"网络请求失败: TimeoutException..."。
class ImportLimitExceeded implements Exception {
  final String message;
  const ImportLimitExceeded(this.message);

  @override
  String toString() => message;
}

/// 导入书源（支持 JSON 文件/网络链接/剪贴板）
class ImportBookSource {
  final BookSourceRepository repository;
  final ParseBookSourceRule parser;
  final DioClient _client;

  /// 空闲超时：下载停顿超过该时长判定挂起
  final Duration idleTimeout;
    /// 首字节超时：连接建立后超过该时长未收到任何数据判定服务器挂起。
    /// 必须大于 Dio 连接+重试最坏耗时（10s×4 + 退避 ≈ 46s），避免误杀合法重试。
    final Duration firstByteTimeout;
  /// 总时限：整个下载不能超过该时长
  final Duration totalLimit;
  /// 单个书源文件最大字节数，防止恶意/异常大文件耗尽内存
  static const int maxSourceBytes = 50 * 1024 * 1024;

  ImportBookSource({
    required this.repository,
    required this.parser,
    DioClient? client,
    SourceSubscriptionStore? subscriptionStore,
    this.idleTimeout = const Duration(seconds: 20),
        this.firstByteTimeout = const Duration(seconds: 60),
    this.totalLimit = const Duration(minutes: 10),
  })  : _client = client ?? DioClient(),
        subscriptionStore =
            subscriptionStore ?? MemorySourceSubscriptionStore();

  /// 订阅存储（§三-9）：成功导入 URL 后记录，供一键刷新。
  /// 默认内存实现（Hive 未初始化环境零依赖）；应用入口注入 Hive 持久实现。
  final SourceSubscriptionStoreBase subscriptionStore;

  /// 从文件导入（支持单个书源 JSON 或书源列表 JSON 数组）
  Future<Either<String, List<BookSource>>> fromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: true,
      // 必需：IO 平台默认不读取文件内容，缺省时 file.bytes 恒为 null
      withData: true,
    );
    if (result == null) return const Left('未选择文件');

    final sources = <BookSource>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      final content = _decodeUtf8(bytes);
      final parsed = await _parseContent(content);
      parsed.fold((l) => null, (r) => sources.addAll(r));
    }
    if (sources.isEmpty) return const Left('未解析到有效书源');

    for (final source in sources) {
      await _saveMerged(source);
    }
    return Right(sources);
  }

  /// 导入合并（P0-12，Legado ImportBookSourceViewModel comparisonSource）：
  /// - 本地不存在 → 直接入库
  /// - 本地 lastUpdateTime 较新 → 跳过（保留本地规则/启用/分组）
  /// - 导入源较新 → 覆盖规则，但保留本地启用状态与分组
  ///   （避免更新把用户手动关闭的源重新打开、打乱本地分组组织）
  Future<void> _saveMerged(BookSource source) async {
    final existing = await repository.getById(source.id);
    if (existing == null) {
      await repository.save(source);
      return;
    }
    if (existing.lastUpdateTime > source.lastUpdateTime) return;
    if (existing.enabled != source.enabled ||
        existing.bookSourceGroup != source.bookSourceGroup) {
      await repository.save(source.copyWith(
        enabled: existing.enabled,
        bookSourceGroup: existing.bookSourceGroup,
      ));
      return;
    }
    await repository.save(source);
  }

  /// 从网络链接导入（支持单个书源 JSON 或书源列表 JSON 数组）。
  /// 采用"空闲超时"语义：只要持续收到数据就不中断（大文件/慢速源可完整下载），
  /// 停顿超过 [idleTimeout] 或超过 [totalLimit] 才判定失败。
  Future<Either<String, List<BookSource>>> fromUrl(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return const Left('请输入书源地址');
    debugPrint('[ImportBookSource] fromUrl 开始: ${redactUrl(trimmed)}');
    try {
      final content = await _downloadWithIdleTimeout(trimmed, onProgress: onProgress, cancelToken: cancelToken);
      debugPrint('[ImportBookSource] 请求完成, 内容长度: ${content.length}');
      return (await _parseContent(content, cancelToken: cancelToken)).fold(
        (error) => Left(error),
        (sources) async {
          for (final source in sources) {
            await _saveMerged(source);
          }
          // 订阅记录（§三-9）：URL 导入成功即视为订阅，一键刷新可重拉；
          // 记录失败不阻断导入主流程
          try {
            await subscriptionStore.recordChecked(trimmed, sourceCount: sources.length);
          } catch (_) {}
          return Right(sources);
        },
      );
    } on ImportLimitExceeded catch (e) {
      // 大小超限/下载超时：直接给出明确文案，不伪装成网络请求失败
      debugPrint('[ImportBookSource] 导入受限: ${e.message}');
      return Left(e.message);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return const Left('已取消下载');
      }
      debugPrint('[ImportBookSource] 请求失败: ${e.type}');
      return Left('网络请求失败: ${_friendlyError(e)}');
    } catch (e) {
      debugPrint('[ImportBookSource] 请求失败: ${e.runtimeType}');
      return Left('网络请求失败: $e');
    }
  }

  /// 空闲超时下载：有数据流入则持续等待，停顿超时或总时限到则失败
  Future<String> _downloadWithIdleTimeout(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    final completer = Completer<String>();
    final internalToken = CancelToken();
    cancelToken?.whenCancel.then((_) => internalToken.cancel());
    DateTime? lastActivity; // null = 尚未收到首字节，空闲计时未启动
    var sizeExceeded = false;
    late final Timer idleTimer;
    late final Timer totalTimer;
        late final Timer firstByteTimer;

    void finish() {
      idleTimer.cancel();
      totalTimer.cancel();
            firstByteTimer.cancel();
    }

    // 空闲检查周期：随 idleTimeout 自适应（1/4，限 100ms~3s），保证检测精度
    final checkInterval = Duration(
      milliseconds: (idleTimeout.inMilliseconds / 4).clamp(100, 3000).round(),
    );
    idleTimer = Timer.periodic(checkInterval, (_) {
      // 空闲窗口从首字节到达起算：连接/重试阶段不占空闲额度，
      // 避免慢服务器合法重试（最坏 ~46s）被 20s 空闲窗口误杀
      final activity = lastActivity;
      if (activity != null &&
          DateTime.now().difference(activity) > idleTimeout) {
        internalToken.cancel();
        finish();
        if (!completer.isCompleted) {
          completer.completeError(
            ImportLimitExceeded('下载中断：${_durationText(idleTimeout)}无数据'),
          );
        }
      }
    });
    // 连接成功但服务器一直不发首字节：不受 Dio connectTimeout 约束，
    // 由首字节超时兜底（否则要等满 totalLimit）
    // 首字节超时：收到首字节（onProgress）即 cancel，回调只可能在首字节
    // 前触发，无需再检查 lastActivity
    firstByteTimer = Timer(firstByteTimeout, () {
      internalToken.cancel();
      finish();
      if (!completer.isCompleted) {
        completer.completeError(
          ImportLimitExceeded('服务器 ${_durationText(firstByteTimeout)}未发送数据'),
        );
      }
    });
    totalTimer = Timer(totalLimit, () {
      internalToken.cancel();
      finish();
      if (!completer.isCompleted) {
        completer.completeError(ImportLimitExceeded('下载超时（${totalLimit.inMinutes} 分钟上限）'));
      }
    });

    _client
        .getStringWithProgress(
          url,
          onProgress: (received, total) {
            lastActivity = DateTime.now();
            firstByteTimer.cancel();
            if (received > maxSourceBytes) {
              sizeExceeded = true;
              internalToken.cancel();
              finish();
              if (!completer.isCompleted) {
                completer.completeError(const ImportLimitExceeded('文件超过大小限制'));
              }
              return;
            }
            onProgress?.call(received, total);
          },
          cancelToken: internalToken,
        )
        .then((content) {
      finish();
      if (!completer.isCompleted) completer.complete(content);
    }).catchError((Object e) {
      finish();
      if (!completer.isCompleted) {
        if (sizeExceeded) {
          completer.completeError(const ImportLimitExceeded('文件超过大小限制'));
        } else {
          completer.completeError(e);
        }
      }
    });

    return completer.future;
  }

  /// 异常转友好提示（不含服务器细节）
  static String _friendlyError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '连接超时';
      case DioExceptionType.connectionError:
        return '无法连接服务器';
      case DioExceptionType.badResponse:
        return '服务器响应异常（${e.response?.statusCode}）';
      case DioExceptionType.cancel:
        return '已取消';
      default:
        return '请求失败';
    }
  }

  /// 从剪贴板导入
  Future<Either<String, List<BookSource>>> fromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data == null || data.text == null || data.text!.isEmpty) {
      return const Left('剪贴板为空');
    }
    return _parseContent(data.text!).fold(
      (l) => Left(l),
      (sources) async {
        for (final source in sources) {
          await _saveMerged(source);
        }
        return Right(sources);
      },
    );
  }

  static String _decodeUtf8(List<int> bytes) {
    final content = utf8.decode(bytes, allowMalformed: true);
    return content.startsWith('\uFEFF') ? content.substring(1) : content;
  }
  /// 时长文案：亚秒级超时（测试/短配置）显示毫秒，避免出现"0 秒"
  static String _durationText(Duration d) {
    return d.inMilliseconds < 1000
        ? '${d.inMilliseconds} 毫秒'
        : '${d.inSeconds} 秒';
  }

  /// 订阅容器最大子地址数（§三-9）：防恶意容器拖垮导入
  static const int _maxSubscriptionUrls = 20;

  /// 订阅容器（§三-9，Legado ImportBookSourceViewModel $.sourceUrls）：
  /// `{"sourceUrls": ["http://...", ...]}` 递归拉取每个子地址合并书源；
  /// 单个子地址失败不中断其余；子容器不递归（深度 1），总数封顶。
  Future<Either<String, List<BookSource>>> _parseContainer(
    List<dynamic> urls,
    CancelToken? cancelToken,
  ) async {
    final sources = <BookSource>[];
    var fetched = 0;
    var failures = 0;
    for (final entry in urls) {
      if (fetched + failures >= _maxSubscriptionUrls) break;
      final sub = entry?.toString().trim() ?? '';
      if (sub.isEmpty || !sub.startsWith('http')) continue;
      try {
        final content =
            await _downloadWithIdleTimeout(sub, cancelToken: cancelToken);
        // 子内容不再识别容器（深度 1）：{"sourceUrls":...} 指回自身的
        // 恶意容器不会形成递归拉取链
        final parsed =
            await _parseContent(content, allowContainer: false);
        parsed.fold(
          (_) => failures++,
          (list) {
            sources.addAll(list);
            fetched++;
          },
        );
      } catch (_) {
        failures++;
      }
    }
    if (sources.isEmpty) {
      return Left(
        failures > 0 ? '订阅子地址均拉取失败（共 $failures 个）' : '订阅容器未包含有效子地址',
      );
    }
    return Right(sources);
  }

  /// 一键更新所有订阅（§三-9）：逐个重新拉取并合并；合并语义沿用
  /// [fromUrl]（本地较新跳过、保留启用与分组）。返回各订阅结果摘要。
  Future<List<SubscriptionRefreshResult>> refreshSubscriptions({
    CancelToken? cancelToken,
  }) async {
    final subs = await subscriptionStore.list();
    final results = <SubscriptionRefreshResult>[];
    for (final sub in subs) {
      final result = await fromUrl(sub.url, cancelToken: cancelToken);
      results.add(result.fold(
        (error) => SubscriptionRefreshResult(url: sub.url, error: error),
        (sources) =>
            SubscriptionRefreshResult(url: sub.url, updated: sources.length),
      ));
    }
    return results;
  }

  /// 解析内容（支持单个书源对象、书源数组或订阅容器）。
  /// [allowContainer]=false 时不再识别订阅容器（订阅子地址内容用——
  /// 容器不递归，防恶意容器链无界拉取，见 _parseContainer）。
  /// 大文件数组解码下沉 worker isolate（compute），避免阻塞主 isolate；
  /// 逐项直接用已解码 Map 构建书源，不做 re-encode/re-decode。
  Future<Either<String, List<BookSource>>> _parseContent(
    String content, {
    CancelToken? cancelToken,
    bool allowContainer = true,
  }) async {
    final text = content.trim();
    if (text.isEmpty) return const Left('内容为空');

    // 订阅容器（§三-9）：{"sourceUrls": [...]}
    if (allowContainer && text.startsWith('{')) {
      try {
        final obj = jsonDecode(text);
        if (obj is Map && obj['sourceUrls'] is List) {
          return _parseContainer(obj['sourceUrls'] as List, cancelToken);
        }
      } catch (_) {
        // 非容器 JSON：回落到单源解析
      }
    }

    if (text.isEmpty) return const Left('内容为空');

    // 尝试解析为数组
    if (text.startsWith('[')) {
      try {
        final list = text.length > _isolateDecodeThreshold
            ? await compute(_decodeArrayJson, text)
            : (jsonDecode(text) as List);
        final sources = <BookSource>[];
        final seen = <String>{};
        for (final item in list) {
          if (item is! Map) continue;
          // decode 结果已是 Map<String,dynamic>（_fromMap 内部会再拷贝一次
          // 供 remove 使用），此处直接透传，避免逐项重复浅拷贝
          final parsed = parser.executeMap(item as Map<String, dynamic>);
          parsed.fold((l) => null, (r) {
            // 按 URL 去重：同一书源重复导入不累积（无 URL 时按稳定 id）
            final key = r.bookSourceUrl?.trim().toLowerCase() ?? r.id;
            if (seen.add(key)) sources.add(r);
          });
        }
        if (sources.isEmpty) return const Left('未解析到有效书源');
        return Right(sources);
      } catch (e) {
        return Left('书源格式错误: $e');
      }
    }

    // 单个书源对象
    final parsed = parser.execute(text);
    return parsed.fold(
      (l) => Left(l),
      (r) => Right([r]),
    );
  }
}

/// 单个书源 JSON 超过该长度（字节）时，数组解码下沉 worker isolate。
/// 常见书源列表几百 KB，isolate 往返开销不值得；21MB 级大列表驻留主 isolate
/// 会阻塞 UI 数秒。
/// 单个书源 JSON 超过该长度时，数组解码下沉 worker isolate。
/// 按 UTF-16 字符数判断（ASCII 1 字符=1 字节，CJK 1 字符≈3 字节）：
/// 512K 字符 ≈ 0.5MB(ASCII)~1.5MB(CJK)，覆盖 1MB+ 字节的常见大列表；
/// 小列表 isolate 往返开销不值得。
const int _isolateDecodeThreshold = 512 * 1024;

/// 在 worker isolate 中解码书源 JSON 数组（compute 要求顶层函数）
List<dynamic> _decodeArrayJson(String text) => jsonDecode(text) as List;

/// 订阅刷新单条结果（§三-9）
class SubscriptionRefreshResult {
  final String url;
  final int? updated;
  final String? error;

  const SubscriptionRefreshResult({required this.url, this.updated, this.error});

  bool get isSuccess => error == null;
}
