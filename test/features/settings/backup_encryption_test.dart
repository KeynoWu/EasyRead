import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/settings/domain/usecases/backup_encryption.dart';

void main() {
  group('BackupEncryption', () {
    test('加密→解密往返一致，中文与特殊字符无损', () {
      const json = '{"书名":"三体","author":"刘慈欣","note":"<>&\\"\'🎉","emoji":"😀"}';
      final encrypted = encryptBackup(json, 'p@ss-口令');
      final decrypted = decryptBackup(encrypted, 'p@ss-口令');
      expect(decrypted, json);
    });

    test('错误口令抛口令异常，不产出明文', () {
      final encrypted = encryptBackup('{"cookie":"session=abc"}', 'correct-pass');
      expect(
        () => decryptBackup(encrypted, 'wrong-pass'),
        throwsA(isA<BackupWrongPasswordException>()),
      );
    });

    test('magic 识别：真加密文件 / 普通 JSON / 随机字节 / 空数据', () {
      expect(isEncryptedBackup(encryptBackup('{"x":1}', 'pass1234')), isTrue);
      expect(isEncryptedBackup(utf8.encode('{"x":1}')), isFalse);
      // magic 开头但头部长度不足（缺盐/nonce）不算加密文件
      expect(isEncryptedBackup(utf8.encode('ERBK1abc')), isFalse);
      expect(
        isEncryptedBackup(
          Uint8List.fromList(List.generate(64, (i) => (i * 37) % 256)),
        ),
        isFalse,
      );
      expect(isEncryptedBackup(Uint8List(0)), isFalse);
    });

    test('格式非法抛格式异常', () {
      // 非加密数据按格式异常处理
      expect(
        () => decryptBackup(utf8.encode('{"x":1}'), 'pass1234'),
        throwsA(isA<BackupFormatException>()),
      );
      // magic 匹配但长度不足以容纳盐+nonce
      final tooShort = Uint8List.fromList([...ascii.encode('ERBK1'), 1, 2, 3]);
      expect(
        () => decryptBackup(tooShort, 'pass1234'),
        throwsA(isA<BackupFormatException>()),
      );
      // magic+盐+nonce 齐全但密文不足一个 GCM tag
      final incomplete = Uint8List.fromList([
        ...ascii.encode('ERBK1'),
        ...List.filled(16, 1),
        ...List.filled(12, 2),
        3, 4, 5,
      ]);
      expect(
        () => decryptBackup(incomplete, 'pass1234'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('PBKDF2 输出 32 字节；同口令同盐一致、异盐/异口令不同', () {
      final saltA = Uint8List.fromList(List.generate(16, (i) => i));
      final saltB = Uint8List.fromList(List.generate(16, (i) => 255 - i));
      final keyA1 = deriveBackupKey('口令', saltA);
      final keyA2 = deriveBackupKey('口令', saltA);
      final keyB = deriveBackupKey('口令', saltB);
      final keyC = deriveBackupKey('另一口令', saltA);
      expect(keyA1.length, 32);
      expect(keyA2, keyA1);
      expect(keyB, isNot(equals(keyA1)));
      expect(keyC, isNot(equals(keyA1)));
    });

    test('同口令两次加密产出不同密文（盐随机）', () {
      final a = encryptBackup('{"same":"data"}', 'pass1234');
      final b = encryptBackup('{"same":"data"}', 'pass1234');
      expect(a, isNot(equals(b)));
    });
  });
}
