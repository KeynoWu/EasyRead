import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/core/database/hive_init.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hive_migrate');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  test('明文旧盒自动迁移到加密盒，数据完整保留', () async {
    final key = Hive.generateSecureKey();

    // 1. 模拟旧版明文盒（含数据）
    final plain = await Hive.openBox<String>('sensitive');
    await plain.putAll({'a': '数据1', 'b': '数据2', 'c': '数据3'});
    await plain.close();

    // 2. 新版加密打开 → 迁移
    final box = await openSensitiveBoxWithKey<String>('sensitive', key);

    // 3. 数据完整保留（而非被 crash recovery 清空）
    expect(box.get('a'), '数据1');
    expect(box.get('b'), '数据2');
    expect(box.get('c'), '数据3');

    // 4. 迁移后盒文件已加密：明文 CRC 不再匹配（二次打开不迁移、数据仍在）
    await box.close();
    final reopened = await openSensitiveBoxWithKey<String>('sensitive', key);
    expect(reopened.get('a'), '数据1');
    expect(reopened.get('c'), '数据3');
  });

  test('加密盒正常打开不受影响，空文件正常创建', () async {
    final key = Hive.generateSecureKey();

    // 全新盒（文件不存在）
    final box = await openSensitiveBoxWithKey<String>('enc1', key);
    await box.put('k', 'v');
    await box.close();
    final reopened = await openSensitiveBoxWithKey<String>('enc1', key);
    expect(reopened.get('k'), 'v');
  });
}
