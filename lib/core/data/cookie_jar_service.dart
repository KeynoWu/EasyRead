import 'package:hive/hive.dart';

/// 书源登录 Cookie 持久化存储，按 sourceId 保存。
class CookieJarService {
  static const String boxName = 'cookie_jar';

  Box<String>? _cachedBox;

  Future<Box<String>> _box() async =>
      _cachedBox ??= await Hive.openBox<String>(boxName);

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
