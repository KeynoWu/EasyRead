/// 用户自定义净化规则
class PurificationRule {
  final String id;
  final String name;       // 规则名称
  final String pattern;    // 匹配表达式（正则或普通文本，见 isRegex）
  final String replacement; // 替换内容（支持 @js: 前缀的 JS 替换模板）
  final bool enabled;      // 是否启用
  final bool isRegex;      // pattern 是否按正则解释（false = 普通文本替换）
  final bool scopeTitle;   // 是否作用于章节标题
  final bool scopeContent; // 是否作用于正文
  final String? scope;     // Legado 作用范围（书名/书源匹配，暂存兼容）
  final String? excludeScope;
  final int? timeoutMillisecond;
  final String? group;     // 规则分组（内置规则按用途分组）
  final int? order;        // 内置规则序号

  const PurificationRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.enabled = true,
    this.isRegex = true,
    this.scopeTitle = true,
    this.scopeContent = true,
    this.scope,
    this.excludeScope,
    this.timeoutMillisecond,
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
    bool? scopeTitle,
    bool? scopeContent,
    String? scope,
    String? excludeScope,
    int? timeoutMillisecond,
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
      scopeTitle: scopeTitle ?? this.scopeTitle,
      scopeContent: scopeContent ?? this.scopeContent,
      scope: scope ?? this.scope,
      excludeScope: excludeScope ?? this.excludeScope,
      timeoutMillisecond: timeoutMillisecond ?? this.timeoutMillisecond,
      group: group ?? this.group,
      order: order ?? this.order,
    );
  }
}
