import 'dart:convert';
import 'package:hive/hive.dart';

/// JS 桥 `cache` 对象的后端存储（对齐 Legado CacheManager 语义，
/// AnalyzeRule.kt:739 bindings["cache"] = CacheManager）：
/// - `cache.get(key)`：读持久值（过期即视为不存在）
/// - `cache.put(key, value, saveTime)`：写入，saveTime=秒数 TTL，0=永久
/// 存储：普通 Hive 盒（非敏感数据，无需加密）。
/// 盒不可用（Hive 未初始化/损坏——Hive 2.2.3 openBox 失败会 completeError
/// + rethrow 双发）时**首次失败即永久降级**为纯内存 map，不阻塞规则执行。
class JsCacheStore {
  static const String boxName = 'js_cache';

  static final JsCacheStore instance = JsCacheStore();

  Box<dynamic>? _cachedBox;
  bool _memoryMode = false;
  final Map<String, String> _memoryFallback = {};

  Future<Box<dynamic>?> _box() async {
    if (_cachedBox != null) return _cachedBox;
    if (_memoryMode) return null;
    // Hive 未初始化（initHive 未跑，如单元测试环境——bookshelf 盒未开）
    // 时直接降级内存：Hive 2.2.3 openBox 失败会 completeError+rethrow
    // 双发，内部 completer 的错误无法被 catch 消化，会以未处理异步错误
    // 击穿测试 zone / 打日志。用 isBoxOpen（仅查内存表，安全）预检，
    // 从根上避免触发 openBox。
    if (!Hive.isBoxOpen('bookshelf')) {
      _memoryMode = true;
      return null;
    }
    try {
      _cachedBox = await Hive.openBox<dynamic>(boxName, crashRecovery: true);
      return _cachedBox;
    } catch (_) {
      // 盒损坏等：降级内存（一次失败后不再重试开盒）
      _memoryMode = true;
      return null;
    }
  }

  /// 读取并清理过期条目，返回 key→value 平面表（注入 JS __cacheStore）。
  /// 每条存 {v: 值, e: 过期毫秒时间戳}，e==0 为永久。
  Future<Map<String, String>> seed() async {
    final box = await _box();
    if (box == null) {
      return Map.of(_memoryFallback);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = <String, String>{};
    final expired = <String>[];
    for (final entry in box.toMap().entries) {
      final raw = entry.value;
      if (raw is String) {
        // 旧版纯字符串值：视为永久
        result[entry.key.toString()] = raw;
        continue;
      }
      if (raw is Map) {
        final v = raw['v'];
        final e = raw['e'];
        if (v is! String) continue;
        if (e is int && e != 0 && e <= now) {
          expired.add(entry.key.toString());
          continue;
        }
        result[entry.key.toString()] = v;
      }
    }
    if (expired.isNotEmpty) {
      try {
        await box.deleteAll(expired);
      } catch (_) {}
    }
    return result;
  }

  /// 持久化本次执行的 cache.put 调用：键 → (值, TTL 秒)
  Future<void> persistPuts(Map<String, (String, int)> puts) async {
    if (puts.isEmpty) return;
    final box = await _box();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in puts.entries) {
      final (value, ttlSeconds) = entry.value;
      final record = ttlSeconds > 0
          ? {'v': value, 'e': now + ttlSeconds * 1000}
          : {'v': value, 'e': 0};
      if (box == null) {
        _memoryFallback[entry.key] = value;
        continue;
      }
      try {
        await box.put(entry.key, record);
      } catch (_) {}
    }
  }

  /// 单键读取（jsLib URL 缓存等）；缺失/过期返回 null
  Future<String?> get(String key) async {
    final seedMap = await seed();
    return seedMap[key];
  }

  /// 单键写入
  Future<void> put(String key, String value, int ttlSeconds) =>
      persistPuts({key: (value, ttlSeconds)});

  /// 从引擎读取 cache.put 调用序列（[key, value, ttl]）
  static List<List<dynamic>> decodePutOps(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return [];
      return [
        for (final raw in decoded)
          if (raw is List) List<dynamic>.from(raw) else const [],
      ];
    } catch (_) {
      return [];
    }
  }
}
