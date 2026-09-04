import 'package:hive/hive.dart';
import '../database/hive_init.dart';

/// 书源登录 Cookie 持久化存储，按 sourceId 保存。
class CookieJarService {
  static const String boxName = 'cookie_jar';

  Box<String>? _cachedBox;

  /// Cookie 属于凭据：与书源规则盒一致，使用 AES 加密盒存储。
  Future<Box<String>> _box() async =>
      _cachedBox ??= await openSensitiveBox<String>(boxName);

  Future<String?> get(String sourceId) async {
    if (sourceId.isEmpty) return null;
    final box = await _box();
    return box.get(sourceId);
  }

  Future<void> set(String sourceId, String cookie) async {
    if (sourceId.isEmpty) return;
    final box = await _box();
    await box.put(sourceId, cookie);
  }

  Future<void> remove(String sourceId) async {
    if (sourceId.isEmpty) return;
    final box = await _box();
    await box.delete(sourceId);
  }

  /// 响应 Set-Cookie 自动回写（P0-11，对齐 Legado CookieManager 语义）：
  /// 把响应的 set-cookie 值按名合并进该源现有 cookie 串（新值覆盖同名，
  /// 其余保留），修复「会话轮换后登录态静默衰减」。
  /// [setCookieValues] 为响应头 set-cookie 的原始值列表（每条可含
  /// Path/Expires 等属性，仅取首段 name=value）。
  Future<void> absorb(String sourceId, List<String> setCookieValues) async {
    if (sourceId.isEmpty || setCookieValues.isEmpty) return;
    final incoming = <String, String>{};
    for (final raw in setCookieValues) {
      final firstPair = raw.split(';').first.trim();
      final eq = firstPair.indexOf('=');
      if (eq <= 0) continue;
      final name = firstPair.substring(0, eq).trim();
      final value = firstPair.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      incoming[name] = value;
    }
    if (incoming.isEmpty) return;
    final current = await get(sourceId) ?? '';
    final merged = <String, String>{};
    for (final part in current.split(';')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      merged[p.substring(0, eq).trim()] = p.substring(eq + 1).trim();
    }
    merged.addAll(incoming);
    await set(
      sourceId,
      merged.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
  }
}
