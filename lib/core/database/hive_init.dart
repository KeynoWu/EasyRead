import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../features/bookshelf/data/models/book_model.dart';
import '../../features/book_source/data/models/book_source_model.dart';
import '../../features/reader/data/models/chapter_model.dart';
import '../../features/reader/data/models/reading_progress_model.dart';

/// Hive 盒子名称常量
class HiveBoxes {
  static const String bookshelf = 'bookshelf';
  static const String bookSources = 'book_sources';
  static const String settings = 'settings';
  static const String chapters = 'chapters';
  static const String readingProgress = 'reading_progress';
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
      // 已存密钥损坏：绝不生成新密钥覆盖旧值——那会让全部加密盒
      // 以新密钥打开失败、旧数据永久不可读。抛出明确错误终止启动，
      // 由上层提示用户（数据问题可定位，而非静默丢失）。
      throw StateError('Hive 加密密钥损坏（长度异常），拒绝覆盖；请检查安全存储或恢复备份');
    }
  } on StateError {
    rethrow;
  } catch (_) {
    // 安全存储读取失败（如 Keystore/Keychain 瞬时不可用）时：
    // 绝不生成新密钥并写回——那会覆盖可能已存在的旧密钥，导致全部加密盒
    // 永久不可读。此时使用仅内存态的临时密钥：本会话新写入的数据加密后
    // 下次启动无法解密（明确降级），但旧密钥物理上保持原样，可恢复。
    debugPrint('[hive] 安全存储读取失败：使用临时内存密钥，不写回以避免覆盖已有密钥');
    return Hive.generateSecureKey();
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
///
/// 迁移采用**打开前 CRC 预检测**而非「先尝试打开再 catch」：
/// Hive 2.2.3 的 openBox 失败时会同时 completeError 内部 completer 并 rethrow，
/// catch 只能捕获其一，另一份成为 unhandled async error（Flutter 中触发红屏）。
/// 因此不能用异常触发迁移；改为直接读盒文件头帧校验 CRC 判断加密状态。
Future<Box<T>> openSensitiveBox<T>(String name) async {
  final key = await _getOrCreateCipherKey();
  return _openSensitiveBoxWithKey<T>(name, key);
}

/// 供测试注入固定密钥的打开入口。
@visibleForTesting
Future<Box<T>> openSensitiveBoxWithKey<T>(String name, List<int> key) {
  return _openSensitiveBoxWithKey<T>(name, key);
}

Future<Box<T>> _openSensitiveBoxWithKey<T>(String name, List<int> key) async {
  // 打开前探测：磁盘上是旧版明文盒 → 先迁移再打开（全程不触发打开异常）
  if (await _isPlainBoxOnDisk(name)) {
    if (Hive.isBoxOpen(name)) {
      await Hive.box(name).close();
    }
    final old = await Hive.openBox<T>(name, crashRecovery: false);
    final data = old.toMap();
    await old.close();
    await Hive.deleteBoxFromDisk(name);
    final box = await Hive.openBox<T>(
      name,
      encryptionCipher: HiveAesCipher(key),
      crashRecovery: false,
    );
    await box.putAll(data);
    return box;
  }
    // 打开前 CRC 预检测：密钥不匹配/盒损坏时 openBox 会抛 HiveError 击穿启动
    // （且 Hive 2.2.3 openBox 失败会 completeError+rethrow 双发，不能靠 catch 兜底）。
    // 与明文迁移同理，用帧 CRC 预检替代异常：首帧对不上 → 备份原文件开新盒；
    // 尾部损坏（写盘崩溃截断）→ 截断到最后一个完整帧，保住前缀数据。
    await _repairEncryptedBoxIfNeeded(name, key);
  return Hive.openBox<T>(
    name,
    encryptionCipher: HiveAesCipher(key),
    crashRecovery: false,
  );
}
/// 加密盒打开前预检与修复（不依赖 openBox 异常，见上方注释）。
///
/// - 首帧 CRC 用密钥派生种子校验失败（密钥不匹配/文件头损坏）：
///   数据在当前密钥下不可读，备份为 `.corrupt-<时间戳>.bak` 后由调用方开新盒。
///   原文件保留，密钥恢复后可人工还原。
/// - 帧链走查发现中途截断/损坏（崩溃截断）：就地截断到最后一个完整帧，
///   保住前缀数据（等效 crashRecovery 的截断语义，但不改变打开参数）。
Future<void> _repairEncryptedBoxIfNeeded(String name, List<int> key) async {
  if (kIsWeb) return;
  final dynamic hiveImpl = Hive;
  final homePath = hiveImpl.homePath as String?;
  if (homePath == null) return;
  final file = File('$homePath/${name.toLowerCase()}.hive');
  if (!await file.exists()) return;
  final bytes = await file.readAsBytes();
  if (bytes.length < 12) return; // 空/新建盒：可正常打开
  // 明文盒由 _isPlainBoxOnDisk 的迁移路径处理，此处不重复判断

  final seed = HiveAesCipher(key).calculateKeyCrc();
  final view = ByteData.sublistView(bytes);
  var offset = 0;
  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) break; // 尾部不足最小帧：截断
    final frameLength = view.getUint32(offset, Endian.little);
    if (frameLength < 8 || offset + frameLength > bytes.length) break;
    final storedCrc = view.getUint32(offset + frameLength - 4, Endian.little);
    final expected = _crc32(bytes, offset: offset, length: frameLength - 4, seed: seed);
    if (storedCrc != expected) break;
    offset += frameLength;
  }
  if (offset == bytes.length) return; // 帧链完整

  if (offset == 0) {
    // 首帧即不可读：密钥不匹配或文件头损坏，备份后开新盒
    final backup = '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}.bak';
    debugPrint('[hive] 加密盒 $name 首帧校验失败（密钥不匹配或已损坏），备份到 $backup 并开新盒');
    await file.rename(backup);
    return;
  }
  debugPrint('[hive] 加密盒 $name 尾部损坏，截断到最后一个完整帧（$offset/${bytes.length} 字节）');
  final raf = await file.open(mode: FileMode.writeOnlyAppend);
  try {
    await raf.truncate(offset);
  } finally {
    await raf.close();
  }
}

/// 检测磁盘上的盒文件是否为旧版明文盒（未加密）。
///
/// 原理：Hive 帧末尾存储 CRC32，其种子为 `cipher?.calculateKeyCrc() ?? 0`。
/// 明文盒的帧 CRC 用种子 0 即可匹配；加密盒用密钥派生种子，明文 CRC 必然不匹配。
/// 空文件 / 帧不完整 / Web（无文件系统）均按「非明文」处理，不会误迁移。
Future<bool> _isPlainBoxOnDisk(String name) async {
  if (kIsWeb) return false;
  // Hive 全局单例实际类型为 HiveImpl，homePath 是其公开字段（接口未声明）
  final dynamic hiveImpl = Hive;
  final homePath = hiveImpl.homePath as String?;
  if (homePath == null) return false;
  final file = File('$homePath/${name.toLowerCase()}.hive');
  if (!await file.exists()) return false;
  final bytes = await file.readAsBytes();
  if (bytes.length < 12) return false;
  final view = ByteData.sublistView(bytes);
  final frameLength = view.getUint32(0, Endian.little);
  // 帧长度字段非法或帧不完整（可能是损坏/加密盒首帧），按非明文处理
  if (frameLength < 8 || frameLength > bytes.length) return false;
  final storedCrc = view.getUint32(frameLength - 4, Endian.little);
  final plainCrc = _crc32(bytes, length: frameLength - 4, seed: 0);
  return storedCrc == plainCrc;
}

/// 与 Hive Crc32 一致的 CRC-32 实现（种子参数化，用于帧校验）。
int _crc32(Uint8List bytes, {int offset = 0, int? length, int seed = 0}) {
  var crc = seed ^ 0xffffffff;
  final end = offset + (length ?? bytes.length);
  for (var i = offset; i < end; i++) {
    crc = _crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
  }
  return crc ^ 0xffffffff;
}

/// 标准 CRC-32 查表（多项式 0xEDB88320，与 Hive 一致）
final List<int> _crcTable = List<int>.generate(256, (i) {
  var c = i;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// 初始化 Hive 存储
Future<void> initHive() async {
  await Hive.initFlutter();
  Hive.registerAdapter(BookModelAdapter());
  Hive.registerAdapter(BookSourceModelAdapter());
  Hive.registerAdapter(ChapterModelAdapter());
  Hive.registerAdapter(ReadingProgressModelAdapter());
  await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
  // 书源/订阅/设置盒含 Cookie、订阅凭据等敏感数据，加密存储
  await openSensitiveBox<BookSourceModel>(HiveBoxes.bookSources);
  await openSensitiveBox(HiveBoxes.settings);
  await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
  await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
}
