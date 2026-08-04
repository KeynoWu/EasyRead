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

  const RegexPurifier({this.rules = const []});

  String purify(String input) {
    var result = input;
    for (final rule in rules) {
      result = result.replaceAll(rule.regex, rule.replacement);
    }
    return result;
  }
}
