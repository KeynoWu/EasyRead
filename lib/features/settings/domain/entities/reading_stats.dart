/// 单日阅读统计
class DailyReadingStats {
  final String date;      // yyyy-MM-dd
  final int readSeconds;  // 当日累计阅读秒数

  const DailyReadingStats({
    required this.date,
    this.readSeconds = 0,
  });

  DailyReadingStats copyWith({
    String? date,
    int? readSeconds,
  }) {
    return DailyReadingStats(
      date: date ?? this.date,
      readSeconds: readSeconds ?? this.readSeconds,
    );
  }
}

/// 阅读统计汇总
class ReadingStatsSummary {
  final int totalSeconds;   // 总阅读时长（秒）
  final int totalDays;      // 阅读天数
  final int maxDaySeconds;  // 最长单日阅读（秒）
  final List<DailyReadingStats> recentDays; // 最近 7 天

  const ReadingStatsSummary({
    this.totalSeconds = 0,
    this.totalDays = 0,
    this.maxDaySeconds = 0,
    this.recentDays = const [],
  });

}
