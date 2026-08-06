import 'js_purifier.dart';

/// 单个替换规则（Dart RegExp 执行）
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

/// 需 JS 引擎执行的净化规则：
/// - pattern 含 JS 特有语法（如 lookbehind `(?<=...)`，Dart RegExp 不支持）
/// - [script] 为 `@js:` 替换模板（脚本内 `result` = 匹配文本，
///   脚本最后表达式的值 = 替换文本）
/// - [replacement] 为普通文本替换内容（非 JS 模板时的替换文本；
///   为空且 [script] 为空 = 删除匹配）
class JsPurifyRule {
  final String pattern;
  final String script;
  final String replacement;

  const JsPurifyRule({
    required this.pattern,
    this.script = '',
    this.replacement = '',
  });
}

/// 正则净化 — 按规则列表逐条替换（Dart 部分同步执行）。
/// JS 规则（lookbehind / @js 模板）由 [purifyAsync] 经 quickjs 执行；
/// 平台无引擎（如 iOS native assets 不可用）时跳过 JS 规则，仅应用
/// Dart 规则，不影响可用性。
class RegexPurifier {
  final List<PurifyRule> rules;
  final List<JsPurifyRule> jsRules;

  /// 编译结果缓存（key: 大小写标志 + pattern），避免每章净化时重复编译
  static final Map<String, RegExp> _regexCache = {};

  const RegexPurifier({this.rules = const [], this.jsRules = const []});

  /// 同步净化：仅 Dart 规则
  String purify(String input) {
    var result = input;
    for (final rule in rules) {
      result = result.replaceAll(_compiled(rule), rule.replacement);
    }
    return result;
  }

  /// 异步净化：Dart 规则 + JS 规则（引擎不可用时 JS 规则静默跳过）
  Future<String> purifyAsync(String input) async {
    var result = purify(input);
    if (jsRules.isEmpty) return result;
    try {
      final purifier = JsPurifier();
      return await purifier.apply(result, jsRules);
    } catch (_) {
      // 引擎初始化/执行异常：保留 Dart 规则结果，不阻塞阅读
      return result;
    }
  }

  static RegExp _compiled(PurifyRule rule) {
    final key = '${rule.caseSensitive ? 1 : 0}:${rule.pattern}';
    return _regexCache.putIfAbsent(
      key,
      () => RegExp(rule.pattern, caseSensitive: rule.caseSensitive),
    );
  }
}
