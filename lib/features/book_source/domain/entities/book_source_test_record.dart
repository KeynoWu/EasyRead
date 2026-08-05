/// 书源批量检测结果记录（独立存储，不改动书源模型）
class BookSourceTestRecord {
  /// 是否可用（搜索能解析出结果）
  final bool usable;

  /// 单次检测响应耗时（毫秒）
  final int responseTimeMs;

  /// 检测时间
  final DateTime testedAt;

  /// 搜索结果数量
  final int resultCount;

  /// 失败原因（null 表示成功）
  final String? error;

  const BookSourceTestRecord({
    required this.usable,
    required this.responseTimeMs,
    required this.testedAt,
    this.resultCount = 0,
    this.error,
  });

  /// 速度档位：>= 阈值标记为慢
  bool get isSlow => responseTimeMs >= slowThresholdMs;

  static const int slowThresholdMs = 3000;

  Map<String, dynamic> toJson() => {
        'usable': usable,
        'response_time_ms': responseTimeMs,
        'tested_at': testedAt.toIso8601String(),
        'result_count': resultCount,
        if (error != null) 'error': error,
      };

  factory BookSourceTestRecord.fromJson(Map<String, dynamic> json) {
    return BookSourceTestRecord(
      usable: json['usable'] is bool ? json['usable'] as bool : false,
      responseTimeMs: json['response_time_ms'] is num
          ? (json['response_time_ms'] as num).toInt()
          : 0,
      testedAt: DateTime.tryParse(json['tested_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      resultCount: json['result_count'] is num
          ? (json['result_count'] as num).toInt()
          : 0,
      error: json['error']?.toString(),
    );
  }
}
