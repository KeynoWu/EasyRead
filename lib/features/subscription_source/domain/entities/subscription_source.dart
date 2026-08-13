/// 订阅源实体（RSS/Atom 源）。
///
/// 字段均容忍缺失：group / lastUpdatedAt 可为空，JSON 反序列化失败时
/// 降级为默认值，不阻断列表展示。
class SubscriptionSource {
  final String id;
  final String name;
  final String url;
  final String? group;
  final DateTime? lastUpdatedAt;

  const SubscriptionSource({
    required this.id,
    required this.name,
    required this.url,
    this.group,
    this.lastUpdatedAt,
  });

  SubscriptionSource copyWith({
    String? name,
    String? url,
    String? group,
    DateTime? lastUpdatedAt,
  }) {
    return SubscriptionSource(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      group: group ?? this.group,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (group != null) 'group': group,
        if (lastUpdatedAt != null)
          'last_updated_at': lastUpdatedAt!.toIso8601String(),
      };

  factory SubscriptionSource.fromJson(Map<String, dynamic> json) {
    return SubscriptionSource(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      group: json['group']?.toString(),
      lastUpdatedAt:
          DateTime.tryParse(json['last_updated_at']?.toString() ?? ''),
    );
  }
}
