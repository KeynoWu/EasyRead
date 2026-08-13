import 'dart:io';

import 'package:easy_read/features/book_source/data/repositories/book_source_repository_impl.dart';
import 'package:easy_read/features/bookshelf/data/repositories/bookshelf_repository_impl.dart';
import 'package:easy_read/features/settings/data/services/webdav_backup_scheduler.dart';
import 'package:easy_read/features/settings/domain/entities/webdav_config.dart';
import 'package:easy_read/features/settings/domain/usecases/backup_restore.dart';
import 'package:easy_read/features/settings/domain/usecases/webdav_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 可注入的假 WebDavSync：记录上传次数并返回预设结果。
/// 测试通过字段赋值配置行为（构造参数保持无参，见各用例）。
class _FakeWebDavSync extends WebDavSync {
  /// null 表示上传成功；非 null 为失败提示。
  String? uploadResult;
  bool throwOnUpload = false;
  bool configured = true;
  int uploadCalls = 0;

  @override
  Future<WebDavConfig> loadConfig() async {
    return WebDavConfig(
      url: configured ? 'https://example.com/dav/' : '',
      username: configured ? 'user' : '',
    );
  }

  @override
  Future<String?> upload(String backupJson) async {
    uploadCalls++;
    if (throwOnUpload) throw Exception('网络异常');
    return uploadResult;
  }
}

/// 可注入的假 BackupRestore：不访问真实数据，直接返回固定 JSON。
class _FakeBackupRestore extends BackupRestore {
  _FakeBackupRestore()
      : super(
          bookshelfRepo: BookshelfRepositoryImpl(),
          sourceRepo: BookSourceRepositoryImpl(),
        );

  int buildCalls = 0;

  @override
  Future<String> buildBackupJson() async {
    buildCalls++;
    return '{"backup": "fake"}';
  }
}

void main() {
  late _FakeWebDavSync fakeSync;
  late _FakeBackupRestore fakeRestore;

  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_webdav_backup').path);
    fakeSync = _FakeWebDavSync();
    fakeRestore = _FakeBackupRestore();
    WebDavBackupScheduler.stop();
  });

  tearDown(() async {
    WebDavBackupScheduler.stop();
    await Hive.deleteFromDisk();
  });

  group('shouldBackupNow', () {
    final now = DateTime(2026, 8, 13, 12).millisecondsSinceEpoch;

    test('未开启时永远不备份', () {
      expect(
        shouldBackupNow(enabled: false, intervalHours: 24, lastBackupAtMs: null, nowMs: now),
        isFalse,
      );
      expect(
        shouldBackupNow(enabled: false, intervalHours: 24, lastBackupAtMs: now - 86400000, nowMs: now),
        isFalse,
      );
    });

    test('从未备份过时立即备份', () {
      expect(
        shouldBackupNow(enabled: true, intervalHours: 24, lastBackupAtMs: null, nowMs: now),
        isTrue,
      );
    });

    test('超过间隔时备份', () {
      // 上次备份 25 小时前，间隔 24 小时 → 已超
      expect(
        shouldBackupNow(enabled: true, intervalHours: 24, lastBackupAtMs: now - 25 * 3600000, nowMs: now),
        isTrue,
      );
      // 恰好等于间隔（24 小时整）→ 视为已到期
      expect(
        shouldBackupNow(enabled: true, intervalHours: 24, lastBackupAtMs: now - 24 * 3600000, nowMs: now),
        isTrue,
      );
    });

    test('未超过间隔时不备份', () {
      expect(
        shouldBackupNow(enabled: true, intervalHours: 24, lastBackupAtMs: now - 3600000, nowMs: now),
        isFalse,
      );
    });

    test('间隔非法（<=0）时即使开启也不备份', () {
      expect(
        shouldBackupNow(enabled: true, intervalHours: 0, lastBackupAtMs: null, nowMs: now),
        isFalse,
      );
    });
  });

  group('WebDavBackupScheduler', () {
    test('设置关闭时 start 不启动 Timer 也不执行备份', () async {
      await WebDavBackupSettings.save(enabled: false, intervalHours: 24);
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(WebDavBackupScheduler.isRunning, isFalse);
      expect(fakeSync.uploadCalls, 0);
      expect(fakeRestore.buildCalls, 0);
    });

    test('WebDAV 未配置时 start 不启动 Timer', () async {
      await WebDavBackupSettings.save(enabled: true, intervalHours: 24);
      fakeSync.configured = false;
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(WebDavBackupScheduler.isRunning, isFalse);
      expect(fakeSync.uploadCalls, 0);
    });

    test('首次启动立即备份，成功则更新 lastBackupAt', () async {
      await WebDavBackupSettings.save(enabled: true, intervalHours: 24);
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(WebDavBackupScheduler.isRunning, isTrue);
      expect(fakeSync.uploadCalls, 1);
      expect(fakeRestore.buildCalls, 1);
      final last = await WebDavBackupSettings.lastBackupAt();
      expect(last, isNotNull);
      // 时间戳在合理范围内（刚执行过）
      expect(
        DateTime.now().millisecondsSinceEpoch - last!,
        lessThan(60000),
      );
    });

    test('距上次备份未超间隔时不立即执行', () async {
      await WebDavBackupSettings.save(enabled: true, intervalHours: 24);
      await WebDavBackupSettings.setLastBackupAt(
        DateTime.now().millisecondsSinceEpoch - 3600000,
      );
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(WebDavBackupScheduler.isRunning, isTrue);
      expect(fakeSync.uploadCalls, 0);
      // lastBackupAt 未被覆盖
      expect(await WebDavBackupSettings.lastBackupAt(), isNotNull);
    });

    test('超过间隔时立即执行备份', () async {
      await WebDavBackupSettings.save(enabled: true, intervalHours: 24);
      await WebDavBackupSettings.setLastBackupAt(
        DateTime.now().millisecondsSinceEpoch - 25 * 3600000,
      );
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(fakeSync.uploadCalls, 1);
    });

    test('上传返回错误时不更新 lastBackupAt 且不抛出', () async {
      await WebDavBackupSettings.save(enabled: true, intervalHours: 24);
      fakeSync.uploadResult = '上传失败: 服务器错误';
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(fakeSync.uploadCalls, 1);
      expect(await WebDavBackupSettings.lastBackupAt(), isNull);
    });

    test('上传抛异常时不更新 lastBackupAt 且不抛出', () async {
      await WebDavBackupSettings.save(enabled: true, intervalHours: 24);
      fakeSync.throwOnUpload = true;
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(fakeSync.uploadCalls, 1);
      expect(await WebDavBackupSettings.lastBackupAt(), isNull);
    });

    test('stop 后取消 Timer', () async {
      await WebDavBackupSettings.save(enabled: true, intervalHours: 24);
      await WebDavBackupScheduler.start(
        backupRestore: fakeRestore,
        webDavSync: fakeSync,
      );
      expect(WebDavBackupScheduler.isRunning, isTrue);
      WebDavBackupScheduler.stop();
      expect(WebDavBackupScheduler.isRunning, isFalse);
    });
  });
}
