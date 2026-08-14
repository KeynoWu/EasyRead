import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:hive/hive.dart';

import '../../domain/usecases/backup_restore.dart';
import '../../domain/usecases/webdav_sync.dart';

/// WebDAV 自动备份设置：独立 Hive 盒持久化。
class WebDavBackupSettings {
  static const String boxName = 'webdav_backup_setting';
  static const String enabledKey = 'enabled';
  static const String intervalHoursKey = 'intervalHours';
  static const String lastBackupAtKey = 'lastBackupAt';

  /// 每天一次的间隔小时数。
  static const int dailyHours = 24;

  /// 每周一次的间隔小时数。
  static const int weeklyHours = 168;

  /// 默认间隔：每天一次。
  static const int defaultIntervalHours = dailyHours;

  static Future<Box<dynamic>> _box() async => Hive.openBox<dynamic>(boxName);

  static Future<bool> isEnabled() async {
    final box = await _box();
    return box.get(enabledKey, defaultValue: false) == true;
  }

  static Future<int> intervalHours() async {
    final box = await _box();
    return box.get(intervalHoursKey, defaultValue: defaultIntervalHours) ??
        defaultIntervalHours;
  }

  /// 上次成功备份的 epoch 毫秒时间戳；从未备份过则为 null。
  static Future<int?> lastBackupAt() async {
    final box = await _box();
    return box.get(lastBackupAtKey);
  }

  static Future<void> save({
    required bool enabled,
    required int intervalHours,
  }) async {
    final box = await _box();
    await box.put(enabledKey, enabled);
    await box.put(intervalHoursKey, intervalHours);
  }

  static Future<void> setLastBackupAt(int epochMs) async {
    final box = await _box();
    await box.put(lastBackupAtKey, epochMs);
  }
}

/// 判定是否需要立即执行一次备份：
/// - 未开启或间隔非法（<=0）→ false；
/// - 从未备份过 → true（立即执行一次）；
/// - 距上次备份超过 [intervalHours] → true；
/// - 否则 false。
bool shouldBackupNow({
  required bool enabled,
  required int intervalHours,
  int? lastBackupAtMs,
  int? nowMs,
}) {
  if (!enabled || intervalHours <= 0) return false;
  final last = lastBackupAtMs;
  if (last == null) return true;
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return now - last >= intervalHours * 3600000;
}

/// WebDAV 自动备份调度器：应用存活期间按设置间隔自动上传备份。
///
/// 备份失败仅 debugPrint 记录、不打扰用户，下轮周期自动重试；
/// 只有成功才更新 lastBackupAt，避免重复上传同一份数据。
class WebDavBackupScheduler {
  WebDavBackupScheduler({this.backupRestore, WebDavSync? webDavSync})
      : webDavSync = webDavSync ?? WebDavSync();

  /// 用于生成备份 JSON；为 null 时跳过备份（静默，不打扰用户）。
  final BackupRestore? backupRestore;

  /// 上传实现，默认新建真实 WebDavSync。
  final WebDavSync webDavSync;

  Timer? _timer;

  /// 备份进行中标记：备份耗时超过周期时防止 periodic 并发触发上传
  bool _backupInProgress = false;

  static WebDavBackupScheduler? _instance;

  /// 启动代次：start/stop 递增；_start 在各 await 后校验代次，
  /// 防止"首次备份上传中用户关闭/重开"导致旧实例继续设置孤儿定时器。
  static int _generation = 0;

  /// 启动自动备份调度（应用启动或设置变更后调用）。
  ///
  /// [backupRestore] 用于生成备份 JSON；[webDavSync] 默认新建，均可注入以便测试。
  static Future<void> start({
    BackupRestore? backupRestore,
    WebDavSync? webDavSync,
  }) async {
    _instance?._stopTimer();
    final scheduler = WebDavBackupScheduler(
      backupRestore: backupRestore,
      webDavSync: webDavSync,
    );
    _instance = scheduler;
    final generation = ++_generation;
    await scheduler._start(generation);
  }

  /// 停止调度并释放单例（应用退出时调用）。
  static void stop() {
    _generation++;
    _instance?._stopTimer();
    _instance = null;
  }

  @visibleForTesting
  static bool get isRunning => _instance?._timer != null;

  Future<void> _start(int generation) async {
    _stopTimer(); // 幂等：先取消可能残留的定时器
    final enabled = await WebDavBackupSettings.isEnabled();
    final intervalHours = await WebDavBackupSettings.intervalHours();
    // 期间被 stop/重启：放弃本次启动，避免孤儿定时器
    if (generation != _generation) return;
    if (!enabled || intervalHours <= 0) {
      debugPrint('[WebDavBackupScheduler] 自动备份未开启，不启动定时器');
      return;
    }
    if (!await _isWebDavConfigured()) {
      if (generation != _generation) return;
      debugPrint('[WebDavBackupScheduler] WebDAV 未配置，不启动定时器');
      return;
    }
    final last = await WebDavBackupSettings.lastBackupAt();
    if (shouldBackupNow(
      enabled: true,
      intervalHours: intervalHours,
      lastBackupAtMs: last,
    )) {
      await _runBackup();
      if (generation != _generation) return;
    }
    _timer = Timer.periodic(Duration(hours: intervalHours), (_) => _runBackup());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<bool> _isWebDavConfigured() async {
    try {
      return (await webDavSync.loadConfig()).isConfigured;
    } catch (_) {
      // 配置读取异常按未配置处理，静默跳过
      return false;
    }
  }

  /// 执行一次备份；任何失败都静默记录，不抛出、不更新 lastBackupAt。
  Future<void> _runBackup() async {
    // 重叠防护：上一轮备份尚未完成（耗时超过周期）时跳过本轮，
    // 避免并发上传互相覆盖 lastBackupAt 或重复推送同一份数据。
    if (_backupInProgress) return;
    _backupInProgress = true;
    try {
      await _doBackup();
    } finally {
      _backupInProgress = false;
    }
  }

  Future<void> _doBackup() async {
    final backupRestore = this.backupRestore;
    if (backupRestore == null) {
      debugPrint('[WebDavBackupScheduler] 缺少 BackupRestore，跳过本次备份');
      return;
    }
    try {
      final json = await backupRestore.buildBackupJson();
      final result = await webDavSync.upload(json);
      if (result != null) {
        debugPrint('[WebDavBackupScheduler] 上传失败（下轮重试）: $result');
        return;
      }
      await WebDavBackupSettings.setLastBackupAt(
        DateTime.now().millisecondsSinceEpoch,
      );
      debugPrint('[WebDavBackupScheduler] 自动备份完成');
    } catch (e) {
      debugPrint('[WebDavBackupScheduler] 备份异常（下轮重试）: $e');
    }
  }
}
