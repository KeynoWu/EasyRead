import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 加密备份文件头 magic（5 字节 ASCII），用于识别加密备份。
const String backupMagic = 'ERBK1';

/// PBKDF2 盐长度（字节）
const int backupSaltLength = 16;

/// AES-GCM nonce 长度（字节）
const int backupNonceLength = 12;

/// PBKDF2-HMAC-SHA256 迭代次数
const int backupPbkdf2Iterations = 100000;

/// 派生密钥长度（32 字节 = AES-256）
const int backupKeyLength = 32;

/// 口令错误：GCM 认证标签校验失败（口令错误或密文被篡改）。
class BackupWrongPasswordException implements Exception {
  final String message;

  const BackupWrongPasswordException([this.message = '口令错误：备份解密失败']);

  @override
  String toString() => message;
}

/// 备份文件格式非法：非加密备份、结构损坏或数据不完整。
class BackupFormatException implements Exception {
  final String message;

  const BackupFormatException(this.message);

  @override
  String toString() => message;
}

/// 判断字节序列是否为 EasyRead 加密备份（magic 匹配且头部完整）。
bool isEncryptedBackup(Uint8List bytes) {
  if (bytes.length <
      backupMagic.length + backupSaltLength + backupNonceLength) {
    return false;
  }
  return String.fromCharCodes(bytes.sublist(0, backupMagic.length)) ==
      backupMagic;
}

/// PBKDF2-HMAC-SHA256 派生 32 字节密钥（口令按 UTF-8 编码，迭代 [backupPbkdf2Iterations] 次）。
Uint8List deriveBackupKey(String password, Uint8List salt) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, backupPbkdf2Iterations, backupKeyLength));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

/// 加密备份：magic(5B) + 盐(16B) + nonce(12B) + AES-GCM 密文（含 16B 认证 tag）。
///
/// 盐与 nonce 每次随机生成（SecureRandom），同口令两次导出密文不同。
Uint8List encryptBackup(String json, String password) {
  final salt = _randomBytes(backupSaltLength);
  final nonce = _randomBytes(backupNonceLength);
  final key = deriveBackupKey(password, salt);
  final ciphertext = _aesGcm(
    key,
    nonce,
    Uint8List.fromList(utf8.encode(json)),
    encrypt: true,
  );
  final result = Uint8List(
    backupMagic.length + salt.length + nonce.length + ciphertext.length,
  );
  result.setRange(0, backupMagic.length, ascii.encode(backupMagic));
  result.setRange(backupMagic.length, backupMagic.length + salt.length, salt);
  result.setRange(
    backupMagic.length + salt.length,
    backupMagic.length + salt.length + nonce.length,
    nonce,
  );
  result.setRange(
    backupMagic.length + salt.length + nonce.length,
    result.length,
    ciphertext,
  );
  return result;
}

/// 解密备份：口令正确返回原始 JSON 字符串。
///
/// 口令错误抛 [BackupWrongPasswordException]；非加密/结构非法抛 [BackupFormatException]。
String decryptBackup(Uint8List bytes, String password) {
  if (!isEncryptedBackup(bytes)) {
    throw const BackupFormatException('非加密备份文件');
  }
  final salt = bytes.sublist(
    backupMagic.length,
    backupMagic.length + backupSaltLength,
  );
  final nonce = bytes.sublist(
    backupMagic.length + backupSaltLength,
    backupMagic.length + backupSaltLength + backupNonceLength,
  );
  final ciphertext = bytes.sublist(
    backupMagic.length + backupSaltLength + backupNonceLength,
  );
  if (ciphertext.length < 16) {
    // 至少应含 16 字节 GCM tag，否则数据不完整
    throw const BackupFormatException('备份文件数据不完整');
  }
  final key = deriveBackupKey(password, salt);
  try {
    final plain = _aesGcm(key, nonce, ciphertext, encrypt: false);
    return utf8.decode(plain);
  } on InvalidCipherTextException {
    // GCM tag 校验失败 = 口令错误（或密文被篡改），绝不回退明文解析
    throw const BackupWrongPasswordException();
  } on FormatException {
    throw const BackupFormatException('解密结果不是合法 UTF-8 文本');
  }
}

/// AES-256-GCM 单次加解密（tag 附于密文尾部；解密时自动校验）。
Uint8List _aesGcm(
  Uint8List key,
  Uint8List nonce,
  Uint8List data, {
  required bool encrypt,
}) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      encrypt,
      AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
    );
  return cipher.process(data);
}

final Random _secureRandom = Random.secure();

Uint8List _randomBytes(int length) {
  return Uint8List.fromList(
    List<int>.generate(length, (_) => _secureRandom.nextInt(256)),
  );
}
