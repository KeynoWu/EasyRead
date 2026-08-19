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
      if (close == -1) continue;
      final body = pattern.substring(i + 1, close);
      // 组后无任何量词时，即使组体可变长也只是线性匹配，无灾难性回溯
      if (!_hasAnyQuantifier(pattern, close + 1)) {
        i = close;
        continue;
      }
      // 组体含可变长量词（.* / .+ / a? 等）或顶层 alternation 时，
      // 组被重复匹配即可产生指数级回溯。精确次数 {20} 同样可能灾难性
      // （如 (.*a){20}），因此这里用「组后有任何量词」而非仅无上界量词。
      if (_bodyHasQuantifier(body) || _hasTopLevelAlternation(body)) {
        return true;
      }
      i = close;
    }
    return false;
  }

  /// 组后是否紧跟任意量词（+、*、?、{...}）
  static bool _hasAnyQuantifier(String pattern, int start) {
    if (start >= pattern.length) return false;
    final ch = pattern[start];
    if (ch == '+' || ch == '*' || ch == '?') return true;
    if (ch == '{') return pattern.indexOf('}', start) != -1;
    return false;
  }

  /// 是否存在顶层 |（不在嵌套组 / 字符类内）
  static bool _hasTopLevelAlternation(String body) {
    var depth = 0;
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
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        if (depth > 0) depth--;
      } else if (ch == '|' && depth == 0) {
        return true;
      }
    }
    return false;
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
