/// 用户自定义净化规则
class PurificationRule {
  final String id;
  final String name;       // 规则名称
  final String pattern;    // 匹配表达式（正则或普通文本，见 isRegex）
  final String replacement; // 替换内容（支持 @js: 前缀的 JS 替换模板）
  final bool enabled;      // 是否启用
  final bool isRegex;      // pattern 是否按正则解释（false = 普通文本替换）
  final String? group;     // 规则分组（内置规则按用途分组）
  final int? order;        // 内置规则序号

  const PurificationRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.enabled = true,
    this.isRegex = true,
    this.group,
    this.order,
  });

  PurificationRule copyWith({
    String? id,
    String? name,
    String? pattern,
    String? replacement,
    bool? enabled,
    bool? isRegex,
    String? group,
    int? order,
  }) {
    return PurificationRule(
      id: id ?? this.id,
      name: name ?? this.name,
      pattern: pattern ?? this.pattern,
      replacement: replacement ?? this.replacement,
      enabled: enabled ?? this.enabled,
      isRegex: isRegex ?? this.isRegex,
      group: group ?? this.group,
      order: order ?? this.order,
    );
  }
}
