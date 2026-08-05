/// 单个替换规则
class PurifyRule {
  final String pattern;
  final String replacement;
  final bool caseSensitive;

  const PurifyRule({
    required this.pattern,
    required this.replacement,
    this.caseSensitive = false,
  });

  RegExp get regex => RegExp(pattern, caseSensitive: caseSensitive);
}

/// 第二阶段：正则净化 — 按规则列表逐条替换
class RegexPurifier {
  final List<PurifyRule> rules;

  /// 编译结果缓存（key: 大小写标志 + pattern），避免每章净化时重复编译
  static final Map<String, RegExp> _regexCache = {};

  const RegexPurifier({this.rules = const []});

  String purify(String input) {
    var result = input;
    for (final rule in rules) {
      result = result.replaceAll(_compiled(rule), rule.replacement);
    }
    return result;
  }

  static RegExp _compiled(PurifyRule rule) {
    final key = '${rule.caseSensitive ? 1 : 0}:${rule.pattern}';
    return _regexCache.putIfAbsent(
      key,
      () => RegExp(rule.pattern, caseSensitive: rule.caseSensitive),
    );
  }
}
