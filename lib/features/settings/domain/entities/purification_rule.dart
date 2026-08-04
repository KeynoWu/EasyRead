/// 用户自定义净化规则
class PurificationRule {
  final String id;
  final String name;       // 规则名称
  final String pattern;    // 正则表达式
  final String replacement; // 替换内容
  final bool enabled;      // 是否启用

  const PurificationRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.enabled = true,
  });

  PurificationRule copyWith({
    String? id,
    String? name,
    String? pattern,
    String? replacement,
    bool? enabled,
  }) {
    return PurificationRule(
      id: id ?? this.id,
      name: name ?? this.name,
      pattern: pattern ?? this.pattern,
      replacement: replacement ?? this.replacement,
      enabled: enabled ?? this.enabled,
    );
  }
}
