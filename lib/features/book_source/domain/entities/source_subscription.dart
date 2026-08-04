/// 书源订阅实体
class SourceSubscription {
  final String id;
  final String name;
  final String url;
  final DateTime? lastUpdatedAt;
  final String? lastUpdateResult; // 最近一次更新的结果信息

  const SourceSubscription({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdatedAt,
    this.lastUpdateResult,
  });

  SourceSubscription copyWith({
    String? id,
    String? name,
    String? url,
    DateTime? lastUpdatedAt,
    String? lastUpdateResult,
  }) {
    return SourceSubscription(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
      lastUpdateResult: lastUpdateResult ?? this.lastUpdateResult,
    );
  }
}
