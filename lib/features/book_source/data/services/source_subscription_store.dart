import 'dart:convert';

import 'package:hive/hive.dart';

/// 书源订阅记录（§三-9 订阅最小方案）
class SourceSubscription {
  final String url;
  final DateTime? lastCheckedAt;
  final int? lastSourceCount;

  const SourceSubscription({
    required this.url,
    this.lastCheckedAt,
    this.lastSourceCount,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'lastCheckedAt': lastCheckedAt?.millisecondsSinceEpoch,
        'lastSourceCount': lastSourceCount,
      };

  static SourceSubscription fromJson(Map<String, dynamic> json) =>
      SourceSubscription(
        url: json['url'] as String,
        lastCheckedAt: json['lastCheckedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['lastCheckedAt'] as int),
        lastSourceCount: json['lastSourceCount'] as int?,
      );
}

/// 订阅存储接口（§三-9）：Hive 持久实现 + 内存默认实现。
/// Hive 未初始化（纯 Dart 测试环境）时 usecase 默认走内存实现，
/// 订阅记录不阻断导入主流程。
abstract class SourceSubscriptionStoreBase {
  Future<List<SourceSubscription>> list();
  Future<void> recordChecked(String url, {int? sourceCount});
  Future<void> remove(String url);
}

/// 内存实现（默认）：进程内会话有效，导入流程零依赖。
class MemorySourceSubscriptionStore implements SourceSubscriptionStoreBase {
  final Map<String, SourceSubscription> _subs = {};

  @override
  Future<List<SourceSubscription>> list() async =>
      _subs.values.toList(growable: false);

  @override
  Future<void> recordChecked(String url, {int? sourceCount}) async {
    _subs[url] = SourceSubscription(
      url: url,
      lastCheckedAt: DateTime.now(),
      lastSourceCount: sourceCount,
    );
  }

  @override
  Future<void> remove(String url) async {
    _subs.remove(url);
  }
}

/// 书源订阅存储（Hive 持久实现）：独立 JSON 字符串盒（key = 订阅 URL
/// 的 FNV 哈希），记录订阅地址与最近一次检查时间，供一键刷新。
class SourceSubscriptionStore implements SourceSubscriptionStoreBase {
  static const String boxName = 'source_subscriptions';

  Future<Box<String>> _box() => Hive.openBox<String>(boxName);

  static String keyOf(String url) {
    var h = 0x811c9dc5;
    for (final code in url.codeUnits) {
      h ^= code;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  @override
  Future<List<SourceSubscription>> list() async {
    final box = await _box();
    final result = <SourceSubscription>[];
    for (final raw in box.values) {
      if (raw.isEmpty) continue;
      try {
        result.add(SourceSubscription.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        ));
      } catch (_) {
        // 损坏条目跳过
      }
    }
    return result;
  }

  /// 记录一次成功检查（不存在则新建订阅）
  @override
  Future<void> recordChecked(String url, {int? sourceCount}) async {
    final box = await _box();
    await box.put(
      keyOf(url),
      jsonEncode(SourceSubscription(
        url: url,
        lastCheckedAt: DateTime.now(),
        lastSourceCount: sourceCount,
      ).toJson()),
    );
  }

  @override
  Future<void> remove(String url) async {
    final box = await _box();
    await box.delete(keyOf(url));
  }
}
