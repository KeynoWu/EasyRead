import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import '../../../../core/network/dio_client.dart';
import '../entities/source_subscription.dart';
import '../entities/book_source.dart';
import '../usecases/parse_book_source_rule.dart';
import '../../data/models/source_subscription_model.dart';
import '../repositories/book_source_repository.dart';

/// 书源订阅管理
class ManageSubscription {
  final BookSourceRepository bookSourceRepository;
  final DioClient _client;

  ManageSubscription({
    required this.bookSourceRepository,
    DioClient? client,
  }) : _client = client ?? DioClient();

  static const String _boxName = 'source_subscriptions';

  Box<SourceSubscriptionModel>? _cachedBox;

  Future<Box<SourceSubscriptionModel>> _box() async =>
      _cachedBox ??= await Hive.openBox<SourceSubscriptionModel>(_boxName);

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

  /// 更新单个订阅
  Future<int> updateSubscription(SourceSubscription subscription) async {
    try {
      final content = await _client.getString(subscription.url);
      final sources = _parseContent(content);

      for (final source in sources) {
        await bookSourceRepository.save(source);
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

  /// 异常转友好提示，避免将服务器细节持久化展示
  static String _friendlyError(Object error) {
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
        default:
          return '请求失败';
      }
    }
    return '未知错误';
  }

  /// 更新所有订阅
  Future<int> updateAll() async {
    final subs = await getAll();
    var total = 0;
    for (final sub in subs) {
      total += await updateSubscription(sub);
    }
    return total;
  }

  /// 解析订阅内容（书源对象或数组）
  List<BookSource> _parseContent(String content) {
    final text = content.trim();
    final sources = <BookSource>[];

    try {
      if (text.startsWith('[')) {
        final list = jsonDecode(text) as List;
        for (final item in list) {
          final map = item as Map<String, dynamic>;
          final rules = Map<String, dynamic>.from(map);
          rules.remove('bookSourceName');
          rules.remove('bookSourceGroup');
          rules.remove('bookSourceUrl');
          sources.add(BookSource(
            id: map['bookSourceUrl']?.toString() ?? ParseBookSourceRule.uniqueFallbackId(),
            name: map['bookSourceName']?.toString() ?? '未命名书源',
            bookSourceUrl: map['bookSourceUrl']?.toString(),
            bookSourceGroup: map['bookSourceGroup']?.toString(),
            rules: rules,
          ));
        }
      } else {
        final map = jsonDecode(text) as Map<String, dynamic>;
        final rules = Map<String, dynamic>.from(map);
        rules.remove('bookSourceName');
        rules.remove('bookSourceGroup');
        rules.remove('bookSourceUrl');
        sources.add(BookSource(
          id: map['bookSourceUrl']?.toString() ?? ParseBookSourceRule.uniqueFallbackId(),
          name: map['bookSourceName']?.toString() ?? '未命名书源',
          bookSourceUrl: map['bookSourceUrl']?.toString(),
          bookSourceGroup: map['bookSourceGroup']?.toString(),
          rules: rules,
        ));
      }
    } catch (e) {
      // 解析失败返回空
    }
    return sources;
  }
}
