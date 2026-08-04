import 'dart:convert';
import 'package:hive/hive.dart';
import '../entities/reading_stats.dart';

/// 阅读统计服务 — 记录每日阅读时长
class ReadingStatsService {
  static const String _boxName = 'reading_stats';

  Box<String>? _cachedBox;

  Future<Box<String>> _box() async =>
      _cachedBox ??= await Hive.openBox<String>(_boxName);

  // ---- 记录 ----

  /// 记录一次阅读会话（分钟数）
  Future<void> recordSession(int seconds) async {
    if (seconds <= 0) return;
    final box = await _box();
    final today = _todayKey();
    final current = _readDay(box, today);
    await box.put(today, jsonEncode({
      'date': today,
      'read_seconds': current.readSeconds + seconds,
    }));
  }

  // ---- 查询 ----

  /// 获取阅读统计汇总
  Future<ReadingStatsSummary> getSummary() async {
    final box = await _box();
    final days = <DailyReadingStats>[];

    for (final key in box.keys) {
      final value = box.get(key);
      if (value == null) continue;
      try {
        final map = jsonDecode(value) as Map<String, dynamic>;
        days.add(DailyReadingStats(
          date: map['date']?.toString() ?? key.toString(),
          readSeconds: (map['read_seconds'] as num?)?.toInt() ?? 0,
        ));
      } catch (_) {
        // 跳过损坏数据
      }
    }

    var total = 0;
    var maxDay = 0;
    for (final day in days) {
      total += day.readSeconds;
      if (day.readSeconds > maxDay) maxDay = day.readSeconds;
    }

    // 最近 7 天（补 0）
    final recentDays = _buildRecentDays(days);

    return ReadingStatsSummary(
      totalSeconds: total,
      totalDays: days.length,
      maxDaySeconds: maxDay,
      recentDays: recentDays,
    );
  }

  // ---- 内部 ----

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  DailyReadingStats _readDay(Box<String> box, String date) {
    final value = box.get(date);
    if (value == null) return DailyReadingStats(date: date);
    try {
      final map = jsonDecode(value) as Map<String, dynamic>;
      return DailyReadingStats(
        date: date,
        readSeconds: (map['read_seconds'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return DailyReadingStats(date: date);
    }
  }

  List<DailyReadingStats> _buildRecentDays(List<DailyReadingStats> all) {
    final byDate = {for (final d in all) d.date: d};
    final result = <DailyReadingStats>[];
    final now = DateTime.now();
    for (int i = 6; i >= 0; i--) {
      final day = now.subtract(Duration(days: i));
      final key = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      result.add(byDate[key] ?? DailyReadingStats(date: key));
    }
    return result;
  }
}
