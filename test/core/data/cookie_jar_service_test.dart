import 'dart:io';
import 'package:easy_read/core/data/cookie_jar_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    // 加密盒密钥存于平台安全存储，测试环境用 mock 保证密钥稳定
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('cookie_jar');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    tempDir.deleteSync(recursive: true);
  });

  test('CookieJarService 按书源持久化 Cookie', () async {
    final service = CookieJarService();
    expect(await service.get('src1'), isNull);

    await service.set('src1', 'session=abc');
    expect(await service.get('src1'), 'session=abc');

    await service.remove('src1');
    expect(await service.get('src1'), isNull);
  });
}
