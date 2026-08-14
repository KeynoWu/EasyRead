import 'js_purifier.dart';

/// 单个替换规则（Dart RegExp 执行）
class PurifyRule {
  final String pattern;
  final String replacement;
  final bool caseSensitive;
  final String? scope;
  final String? excludeScope;

  const PurifyRule({
    required this.pattern,
    required this.replacement,
    this.caseSensitive = false,
    this.scope,
    this.excludeScope,
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
  final String? scope;
  final String? excludeScope;

  const JsPurifyRule({
    required this.pattern,
    this.script = '',
    this.replacement = '',
    this.scope,
    this.excludeScope,
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
  /// 缓存上限：恶意/异常导入大量不同 pattern 时防止无界膨胀。
  /// 超过上限整体清空（净化规则数量级远小于该值，清空代价可忽略）。
  static const int _regexCacheMax = 256;

  const RegexPurifier({this.rules = const [], this.jsRules = const []});

  /// 按书名/书源过滤 Legado scope/excludeScope 后返回新的执行器。
  RegexPurifier scopedFor({String? bookName, String? sourceName}) {
    return RegexPurifier(
      rules: [
        for (final rule in rules)
          if (_matchesScope(rule.scope, rule.excludeScope, bookName, sourceName))
            rule,
      ],
      jsRules: [
        for (final rule in jsRules)
          if (_matchesScope(rule.scope, rule.excludeScope, bookName, sourceName))
            rule,
      ],
    );
  }

  static bool _matchesScope(
    String? scope,
    String? excludeScope,
    String? bookName,
    String? sourceName,
  ) {
    final target = '${bookName ?? ''}|${sourceName ?? ''}';
    if (excludeScope != null && excludeScope.trim().isNotEmpty) {
      for (final item in excludeScope.split(',')) {
        if (item.trim().isNotEmpty && target.contains(item.trim())) return false;
      }
    }
    if (scope == null || scope.trim().isEmpty) return true;
    for (final item in scope.split(',')) {
      if (item.trim().isNotEmpty && target.contains(item.trim())) return true;
    }
    return false;
  }

  /// 同步净化：仅 Dart 规则
  String purify(String input) {
    var result = input;
    for (final rule in rules) {
      result = result.replaceAllMapped(
        _compiled(rule),
        // 字面替换语义：与 JS 路径（js_purifier._expandCaptures）保持一致。
        // Dart 的 replaceAll 会把 replacement 中的 $ 当模板语法解析
        // （$1/$&/$$ 会抛错或错误替换），而 Legado 净化规则的
        // replacement 是纯文本（可含金额等字面 $），必须逐匹配字面替换。
        (_) => rule.replacement,
      );
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
    if (_regexCache.length >= _regexCacheMax && !_regexCache.containsKey(key)) {
      _regexCache.clear();
    }
    return _regexCache.putIfAbsent(
      key,
      () => RegExp(rule.pattern, caseSensitive: rule.caseSensitive),
    );
  }
}
