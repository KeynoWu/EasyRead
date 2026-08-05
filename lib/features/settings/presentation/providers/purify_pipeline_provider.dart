import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../../../core/purification/regex_purifier.dart';
import '../../domain/usecases/manage_purification_rules.dart';

/// 净化规则 ReDoS 预检：检测嵌套量词（如 `(a+)+`、`(a*)*`、`(a+){2,}`、`(a?)+`）等
/// 可能引发灾难性回溯的模式。命中时应拒绝保存并提示用户简化表达式。
class PurifyPatternGuard {
  PurifyPatternGuard._();

  /// 返回 true 表示模式存在灾难性回溯（ReDoS）风险。
  ///
  /// 启发式：组内含有量词（`+`/`*`/`?`/`{n,m}`/`{n,}`）且组后紧跟无上界量词
  /// （`+`/`*`/`{n,}`）。占有量词（`++`/`*+`）不回溯、精确次数 `{n}` 是确定性的，
  /// 均不判为风险。转义字符、字符类内的符号不视为量词。
  static bool hasCatastrophicBacktracking(String pattern) {
    if (pattern.isEmpty) return false;
    for (var i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      if (ch == '\\') {
        i++;
        continue;
      }
      if (ch == '[') {
        i = _skipCharClass(pattern, i);
        continue;
      }
      if (ch != '(') continue;

      final close = _findGroupEnd(pattern, i);
      if (close == -1) continue; // 括号未闭合，交给 RegExp 合法性校验

      // 组体起点：跳过 (?: / (?= / (?! / (?<= / (?<! 前缀
      var bodyStart = i + 1;
      if (i + 2 < pattern.length && pattern[i + 1] == '?') {
        final p = pattern[i + 2];
        if (p == ':' || p == '=' || p == '!') {
          bodyStart = i + 3;
        } else if (p == '<' && i + 3 < pattern.length &&
            (pattern[i + 3] == '=' || pattern[i + 3] == '!')) {
          bodyStart = i + 4;
        }
      }
      final body = pattern.substring(bodyStart, close);

      final qLen = _unboundedQuantifierLength(pattern, close + 1);
      if (qLen == 0) continue;
      // 占有量词（如 (a+)++）不回溯，不构成风险
      final after = close + 1 + qLen;
      if (after < pattern.length && pattern[after] == '+') continue;
      if (_bodyHasQuantifier(body)) return true;
    }
    return false;
  }

  /// 从 [start] 起的无上界量词长度：`+`/`*` 为 1，`{n,}` 为括号总长，否则 0
  static int _unboundedQuantifierLength(String pattern, int start) {
    if (start >= pattern.length) return 0;
    final ch = pattern[start];
    if (ch == '+' || ch == '*') return 1;
    if (ch == '{') {
      final end = pattern.indexOf('}', start);
      if (end == -1) return 0;
      final spec = pattern.substring(start + 1, end);
      // 仅无上界（如 {2,}）与上界可超大的区间构成灾难性回溯风险
      if (RegExp(r'^\d+\s*,\s*\d*\s*$').hasMatch(spec)) {
        final comma = spec.indexOf(',');
        final upper = spec.substring(comma + 1).trim();
        if (upper.isEmpty) return end - start + 1; // {n,} 无上界
        if (int.tryParse(upper) != null && int.parse(upper) > 100) {
          return end - start + 1; // {n,巨大} 近似无上界
        }
      }
    }
    return 0;
  }

  /// 组体是否含量词（+、*、?、{n,m}/{n,}）。精确次数 {n} 是确定性的，不算风险。
  static bool _bodyHasQuantifier(String body) {
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch == '\\') {
        i++;
        continue;
      }
      if (ch == '[') {
        i = _skipCharClass(body, i);
        continue;
      }
      if (ch == '+' || ch == '*' || ch == '?') return true;
      if (ch == '{') {
        final end = body.indexOf('}', i);
        if (end == -1) return true;
        final spec = body.substring(i + 1, end);
        if (!RegExp(r'^\d+$').hasMatch(spec)) return true;
        i = end;
      }
    }
    return false;
  }

  /// 找到 [open] 处 `(` 的匹配 `)`；忽略转义与字符类内的括号，未闭合返回 -1
  static int _findGroupEnd(String pattern, int open) {
    var depth = 1;
    for (var i = open + 1; i < pattern.length; i++) {
      final ch = pattern[i];
      if (ch == '\\') {
        i++;
        continue;
      }
      if (ch == '[') {
        i = _skipCharClass(pattern, i);
        continue;
      }
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// 跳过字符类 `[...]`（[start] 指向 `[`），返回 `]` 的下标（未闭合则返回末尾）
  static int _skipCharClass(String pattern, int start) {
    for (var i = start + 1; i < pattern.length; i++) {
      if (pattern[i] == '\\') {
        i++;
        continue;
      }
      if (pattern[i] == ']') return i;
    }
    return pattern.length - 1;
  }
}

/// 用户配置的净化规则 → 净化管线。
/// 规则存放在 Hive（异步读取），加载完成后通过 [PurifyPipeline] 注入阅读仓库。
final purifyPipelineProvider = FutureProvider<PurifyPipeline>((ref) async {
  final rules = await ManagePurificationRules().getAll();
  final enabled = <PurifyRule>[];
  for (final rule in rules) {
    if (!rule.enabled || rule.pattern.isEmpty) continue;
    try {
      RegExp(rule.pattern); // 校验正则合法性，非法规则跳过避免运行期崩溃
      // ReDoS 预检：跳过可能灾难性回溯的历史规则，避免阅读时卡死
      if (PurifyPatternGuard.hasCatastrophicBacktracking(rule.pattern)) continue;
      enabled.add(PurifyRule(pattern: rule.pattern, replacement: rule.replacement));
    } catch (_) {
      // 忽略非法正则
    }
  }
  return PurifyPipeline(regexPurifier: RegexPurifier(rules: enabled));
});
