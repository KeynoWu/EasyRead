import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/subscription_source.dart';

/// 订阅源 CRUD 存储：JSON 字符串盒（key = 源 id）。
///
/// 与既有 BookSourceTestStore / SearchHistoryService 模式一致，
/// 无需注册 TypeAdapter，也不占用 Hive 类型 id。
class SubscriptionSourceService {
  static const String boxName = 'subscription_sources';

  Future<Box<String>> _box() => Hive.openBox<String>(boxName);

  /// 新增或更新订阅源（同 id 覆盖）。
  Future<void> save(SubscriptionSource source) async {
    final box = await _box();
    await box.put(source.id, jsonEncode(source.toJson()));
  }

  /// 按 id 查询；不存在或数据损坏时返回 null。
  Future<SubscriptionSource?> getById(String id) async {
    final box = await _box();
    final raw = box.get(id);
    if (raw == null || raw.isEmpty) return null;
    try {
      return SubscriptionSource.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 全部订阅源（按名称排序，展示稳定）；损坏条目自动跳过。
  Future<List<SubscriptionSource>> getAll() async {
    final box = await _box();
    final result = <SubscriptionSource>[];
    for (final entry in box.toMap().entries) {
      final raw = entry.value;
      if (raw.isEmpty) continue;
      try {
        result.add(SubscriptionSource.fromJson(
            jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {
        // 损坏条目跳过，不阻断整体读取
      }
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  /// 删除订阅源。
  Future<void> remove(String id) async {
    final box = await _box();
    await box.delete(id);
  }

  /// 更新最近拉取时间（源不存在时静默忽略）。
  Future<void> updateLastUpdatedAt(String id, DateTime time) async {
    final source = await getById(id);
    if (source == null) return;
    await save(source.copyWith(lastUpdatedAt: time));
  }

  /// 清空全部订阅源（测试用）。
  Future<void> clear() async {
    final box = await _box();
    await box.clear();
  }
}
