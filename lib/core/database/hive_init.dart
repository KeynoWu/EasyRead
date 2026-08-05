import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../features/bookshelf/data/models/book_model.dart';
import '../../features/book_source/data/models/book_source_model.dart';
import '../../features/book_source/data/models/source_subscription_model.dart';
import '../../features/reader/data/models/chapter_model.dart';
import '../../features/reader/data/models/reading_progress_model.dart';

/// Hive 盒子名称常量
class HiveBoxes {
  static const String bookshelf = 'bookshelf';
  static const String bookSources = 'book_sources';
  static const String settings = 'settings';
  static const String chapters = 'chapters';
  static const String readingProgress = 'reading_progress';
  static const String sourceSubscriptions = 'source_subscriptions';
  static const String bookDetails = 'book_details';
}

/// 加密盒密钥在平台安全存储（iOS Keychain / Android Keystore）中的 key。
/// 版本号后缀：未来轮换密钥时更换 key 名并迁移。
const String _cipherKeyName = 'hive_cipher_key_v1';

const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

/// 读取或生成 Hive 加密密钥（32 字节 AES-256）。
Future<List<int>> _getOrCreateCipherKey() async {
  try {
    final existing = await _secureStorage.read(key: _cipherKeyName);
    if (existing != null) {
      final bytes = base64Decode(existing);
      if (bytes.length == 32) return bytes;
    }
  } catch (_) {
    // 安全存储不可用时回退到新密钥（数据将无法解密读取，属极端降级）
  }
  final key = Hive.generateSecureKey();
  try {
    await _secureStorage.write(key: _cipherKeyName, value: base64Encode(key));
  } catch (_) {
    // 写入失败不阻断启动：本次会话密钥仍可加密新盒
  }
  return key;
}

/// 打开含敏感数据的盒子（书源规则含 Cookie 等凭据）。
/// 优先以 AES 加密打开；若磁盘上是旧版明文数据，自动迁移为加密存储。
Future<Box<T>> openSensitiveBox<T>(String name) async {
  final key = await _getOrCreateCipherKey();
  try {
    return await Hive.openBox<T>(name, encryptionCipher: HiveAesCipher(key));
  } catch (_) {
    // 明文旧盒无法用 cipher 打开 → 读出数据、重建加密盒、写回
    if (Hive.isBoxOpen(name)) {
      await Hive.box(name).close();
    }
    final Box<T> old = await Hive.openBox(name);
    final data = old.toMap();
    await old.close();
    await Hive.deleteBoxFromDisk(name);
    final box = await Hive.openBox<T>(name, encryptionCipher: HiveAesCipher(key));
    await box.putAll(data);
    return box;
  }
}

/// 初始化 Hive 存储
Future<void> initHive() async {
  await Hive.initFlutter();
  Hive.registerAdapter(BookModelAdapter());
  Hive.registerAdapter(BookSourceModelAdapter());
  Hive.registerAdapter(SourceSubscriptionModelAdapter());
  Hive.registerAdapter(ChapterModelAdapter());
  Hive.registerAdapter(ReadingProgressModelAdapter());
  await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
  // 书源/订阅/设置盒含 Cookie、订阅凭据等敏感数据，加密存储
  await openSensitiveBox<BookSourceModel>(HiveBoxes.bookSources);
  await openSensitiveBox(HiveBoxes.settings);
  await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
  await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
  await openSensitiveBox<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
}
