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
}
