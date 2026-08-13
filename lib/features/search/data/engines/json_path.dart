import 'dart:convert';

/// JSONPath 引擎 — 支持 Legado 常用子集：
/// - `$` 根、`.key` 属性、`['key']` 属性
/// - `..key` 递归下降（收集所有层级的 key）
/// - `[*]` 展开数组、`[N]` 索引
/// - `[?(expr)]` 过滤：`@` 绑定数组元素，支持比较、&&/||、括号分组
/// - `expr1&&expr2` 组合：前一个无结果时用后一个（Legado 语义）
class JsonPathEngine {
  static final JsonPathEngine instance = JsonPathEngine();

  /// 查询 JSON 数据，返回匹配值列表（空 = 无结果）
  List<dynamic> query(dynamic data, String path) {
    if (path.isEmpty) return [];
    // Legado && 组合：取第一个有结果的表达式（忽略过滤器 [?(...)] 内部的 &&）
    if (path.contains('&&')) {
      for (final expr in _splitTopLevelAnd(path)) {
        final result = _querySingle(data, expr.trim());
        if (result.isNotEmpty) return result;
      }
      return [];
    }
    return _querySingle(data, path);
  }

  List<dynamic> _querySingle(dynamic data, String path) {
    final steps = _parse(path);
    if (steps.isEmpty) return [];
    var current = <dynamic>[data];
    for (final step in steps) {
      current = _applyStep(current, step);
      if (current.isEmpty) return [];
    }
    return current;
  }

  List<dynamic> _applyStep(List<dynamic> current, _Step step) {
    final result = <dynamic>[];
    switch (step) {
      case _KeyStep(:final key):
        for (final node in current) {
          if (node is Map) {
            final value = node[key];
            if (value != null) result.add(value);
          }
        }
      case _RecursiveStep(:final key):
        for (final node in current) {
          _collectRecursive(node, key, result);
        }
      case _AllStep():
        for (final node in current) {
          if (node is List) result.addAll(node);
        }
      case _IndexStep(:final index):
        for (final node in current) {
          if (node is List && index >= 0 && index < node.length) {
            result.add(node[index]);
          }
        }
      case _FilterStep(:final expression):
        // 表达式语法错误时跳过该步（原样返回），与整体容错一致
        final expr = _FilterParser(expression).parse();
        if (expr == null) return current;
        for (final node in current) {
          if (node is List) {
            for (final element in node) {
              if (_truthy(expr.eval(element))) result.add(element);
            }
          }
        }
    }
    return result;
  }

  /// 按顶层 && 拆分（Legado 组合语义），忽略 [?(...)] 过滤器内部、
  /// ['key'] 属性名与字符串字面量中的 &&，避免误拆过滤表达式
  List<String> _splitTopLevelAnd(String path) {
    final parts = <String>[];
    var depth = 0; // [ 嵌套深度（过滤器内部为 1+）
    var quote = 0; // 0=无 1=单引号 2=双引号
    var start = 0;
    for (var i = 0; i < path.length; i++) {
      final c = path[i];
      if (quote == 1) {
        if (c == '\\') {
          i++; // 转义字符：跳过下一个（与 _parseString 一致）
          continue;
        }
        if (c == "'") quote = 0;
      } else if (quote == 2) {
        if (c == '\\') {
          i++;
          continue;
        }
        if (c == '"') quote = 0;
      } else if (c == "'") {
        quote = 1;
      } else if (c == '"') {
        quote = 2;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        if (depth > 0) depth--;
      } else if (c == '&' &&
          i + 1 < path.length &&
          path[i + 1] == '&' &&
          depth == 0) {
        parts.add(path.substring(start, i));
        i++; // 跳过第二个 &
        start = i + 1;
      }
    }
    parts.add(path.substring(start));
    return parts;
  }

  /// 递归收集所有层级 Map 中 [key] 的值
  void _collectRecursive(dynamic node, String key, List<dynamic> out) {
    if (node is Map) {
      final value = node[key];
      if (value != null) out.add(value);
      for (final child in node.values) {
        _collectRecursive(child, key, out);
      }
    } else if (node is List) {
      for (final child in node) {
        _collectRecursive(child, key, out);
      }
    }
  }

  List<_Step> _parse(String path) {
    var rest = path.trim();
    if (rest.startsWith(r'$')) rest = rest.substring(1);
    final steps = <_Step>[];
    while (rest.isNotEmpty) {
      if (rest.startsWith('..')) {
        rest = rest.substring(2);
        final (key, remaining) = _readKey(rest);
        if (key == null) return [];
        rest = remaining;
        steps.add(_RecursiveStep(key));
      } else if (rest.startsWith('.')) {
        rest = rest.substring(1);
        final (key, remaining) = _readKey(rest);
        if (key == null) return [];
        rest = remaining;
        steps.add(_KeyStep(key));
      } else if (rest.startsWith('[')) {
        final close = _findCloseBracket(rest);
        if (close < 0) return [];
        final inner = rest.substring(1, close).trim();
        rest = rest.substring(close + 1);
        if (inner == '*') {
          steps.add(_AllStep());
        } else if (inner.startsWith('?(') && inner.endsWith(')')) {
          // 过滤表达式 [?(...)]：@ 绑定到数组元素
          steps.add(_FilterStep(inner.substring(2, inner.length - 1)));
        } else {
          final index = int.tryParse(inner);
          if (index == null) return [];
          steps.add(_IndexStep(index));
        }
      } else {
        return [];
      }
    }
    return steps;
  }

  /// 找配对的 ]：按引号与嵌套括号感知扫描，
  /// 兼容过滤表达式内的 @['key'] 与字符串字面量中的 ] / )
  int _findCloseBracket(String s) {
    var depth = 0;
    var quote = 0; // 0=无 1=单引号 2=双引号
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote == 1) {
        if (c == '\\') {
          i++; // 转义字符：跳过下一个（与 _parseString 一致）
          continue;
        }
        if (c == "'") quote = 0;
      } else if (quote == 2) {
        if (c == '\\') {
          i++;
          continue;
        }
        if (c == '"') quote = 0;
      } else if (c == "'") {
        quote = 1;
      } else if (c == '"') {
        quote = 2;
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// 读取属性名（.key 或 ['key']），返回 (属性名, 剩余路径)
  (String?, String) _readKey(String rest) {
    if (rest.startsWith("['")) {
      final close = rest.indexOf("']");
      if (close < 0) return (null, rest);
      return (rest.substring(2, close), rest.substring(close + 2));
    }
    final match = RegExp(r'^[A-Za-z0-9_\u4e00-\u9fa5]+').firstMatch(rest);
    if (match == null) return (null, rest);
    return (match.group(0), rest.substring(match.end));
  }

  /// 便捷：解析字符串为 JSON 后查询
  static List<dynamic> queryString(String json, String path) {
    try {
      return instance.query(jsonDecode(json), path);
    } catch (_) {
      return [];
    }
  }
}

sealed class _Step {}

class _KeyStep extends _Step {
  final String key;
  _KeyStep(this.key);
}

class _RecursiveStep extends _Step {
  final String key;
  _RecursiveStep(this.key);
}

class _AllStep extends _Step {
  _AllStep();
}

class _IndexStep extends _Step {
  final int index;
  _IndexStep(this.index);
}

/// 过滤步骤 `[?(expr)]`：对数组元素求值表达式（@ 绑定元素）
class _FilterStep extends _Step {
  /// 过滤表达式（不含 `[?(` 与末尾 `)` 包裹），如 `@.id==1`
  final String expression;
  _FilterStep(this.expression);
}

/// 过滤表达式 AST 节点：以数组元素（@ 绑定）为根求值
sealed class _FilterExpr {
  dynamic eval(dynamic root);
}

class _FilterOr extends _FilterExpr {
  final List<_FilterExpr> parts;
  _FilterOr(this.parts);

  @override
  dynamic eval(dynamic root) {
    for (final p in parts) {
      if (_truthy(p.eval(root))) return true;
    }
    return false;
  }
}

class _FilterAnd extends _FilterExpr {
  final List<_FilterExpr> parts;
  _FilterAnd(this.parts);

  @override
  dynamic eval(dynamic root) {
    for (final p in parts) {
      if (!_truthy(p.eval(root))) return false;
    }
    return true;
  }
}

class _FilterCompare extends _FilterExpr {
  final String op;
  final _FilterExpr left;
  final _FilterExpr right;
  _FilterCompare(this.op, this.left, this.right);

  @override
  dynamic eval(dynamic root) {
    return _compareValues(op, left.eval(root), right.eval(root));
  }
}

class _FilterOperand extends _FilterExpr {
  /// 属性访问链；空列表 = 裸 @（元素本身）
  final List<String> keys;
  final dynamic literal;
  final bool isLiteral;
  _FilterOperand(this.keys) : literal = null, isLiteral = false;
  _FilterOperand.literal(this.literal)
      : keys = const [],
        isLiteral = true;

  @override
  dynamic eval(dynamic root) {
    if (isLiteral) return literal;
    dynamic v = root;
    for (final k in keys) {
      if (v is Map) {
        v = v[k];
      } else {
        return null; // 中间缺值（与 JS 的 undefined 语义一致）
      }
    }
    return v;
  }
}

/// 过滤表达式解析器（递归下降）：
/// - 操作数：@.key / @['key'] / 嵌套 @.a.b / 裸 @；
///   字符串（单双引号）、数字、true / false / null 字面量
/// - 运算符：== != > >= < <=；逻辑 && ||；括号分组 ( )
/// - 语法错误返回 null（调用方跳过该步，与整体容错一致）
class _FilterParser {
  final String src;
  int pos = 0;
  _FilterParser(this.src);

  bool get _end => pos >= src.length;

  void _skipWs() {
    while (pos < src.length &&
        (src[pos] == ' ' ||
            src[pos] == '\t' ||
            src[pos] == '\r' ||
            src[pos] == '\n')) {
      pos++;
    }
  }

  /// 解析完整表达式；语法错误返回 null
  _FilterExpr? parse() {
    _skipWs();
    if (_end) return null;
    final expr = _parseOr();
    if (expr == null) return null;
    _skipWs();
    if (!_end) return null; // 尾部多余内容
    return expr;
  }

  _FilterExpr? _parseOr() {
    _skipWs();
    final first = _parseAnd();
    if (first == null) return null;
    var parts = <_FilterExpr>[first];
    while (true) {
      _skipWs();
      if (!_match('||')) break;
      final e = _parseAnd();
      if (e == null) return null;
      parts.add(e);
    }
    return parts.length == 1 ? first : _FilterOr(parts);
  }

  _FilterExpr? _parseAnd() {
    _skipWs();
    final first = _parseCmp();
    if (first == null) return null;
    var parts = <_FilterExpr>[first];
    while (true) {
      _skipWs();
      if (!_match('&&')) break;
      final e = _parseCmp();
      if (e == null) return null;
      parts.add(e);
    }
    return parts.length == 1 ? first : _FilterAnd(parts);
  }

  _FilterExpr? _parseCmp() {
    _skipWs();
    final left = _parsePrimary();
    if (left == null) return null;
    _skipWs();
    final op = _matchOp();
    if (op == null) return left;
    _skipWs();
    final right = _parsePrimary();
    if (right == null) return null;
    return _FilterCompare(op, left, right);
  }

  _FilterExpr? _parsePrimary() {
    _skipWs();
    if (_end) return null;
    if (src[pos] == '(') {
      pos++;
      final inner = _parseOr();
      _skipWs();
      if (inner == null || _end || src[pos] != ')') return null;
      pos++;
      return inner;
    }
    if (src[pos] == '@') {
      pos++;
      final keys = _parseAccessPath();
      if (keys == null) return null;
      return _FilterOperand(keys);
    }
    return _parseLiteral();
  }

  /// @ 之后的访问路径：.key / ['key'] 组合；语法错误返回 null
  List<String>? _parseAccessPath() {
    final keys = <String>[];
    while (true) {
      _skipWs();
      if (pos < src.length && src[pos] == '.') {
        pos++;
        _skipWs();
        final key = _readIdent();
        if (key == null) return null;
        keys.add(key);
      } else if (src.startsWith("['", pos)) {
        pos += 2;
        final close = src.indexOf("']", pos);
        if (close < 0) return null;
        keys.add(src.substring(pos, close));
        pos = close + 2;
      } else {
        break;
      }
    }
    return keys;
  }

  String? _readIdent() {
    final match =
        RegExp(r'^[A-Za-z0-9_\u4e00-\u9fa5]+').firstMatch(src.substring(pos));
    if (match == null) return null;
    pos += match.group(0)!.length;
    return match.group(0);
  }

  String? _matchOp() {
    if (pos + 1 < src.length) {
      final two = src.substring(pos, pos + 2);
      if (two == '>=' || two == '<=' || two == '==' || two == '!=') {
        pos += 2;
        return two;
      }
    }
    if (pos < src.length && (src[pos] == '>' || src[pos] == '<')) {
      pos++;
      return src[pos - 1];
    }
    return null;
  }

  bool _match(String s) {
    if (src.startsWith(s, pos)) {
      pos += s.length;
      return true;
    }
    return false;
  }

  _FilterExpr? _parseLiteral() {
    _skipWs();
    if (_end) return null;
    final c = src[pos];
    if (c == "'" || c == '"') {
      final s = _parseString();
      if (s == null) return null;
      return _FilterOperand.literal(s);
    }
    final numMatch =
        RegExp(r'^-?\d+(\.\d+)?').firstMatch(src.substring(pos));
    if (numMatch != null) {
      final raw = numMatch.group(0)!;
      pos += raw.length;
      return _FilterOperand.literal(
          raw.contains('.') ? double.parse(raw) : int.parse(raw));
    }
    for (final kw in ['true', 'false', 'null']) {
      if (src.startsWith(kw, pos)) {
        final after = pos + kw.length;
        if (after < src.length && RegExp(r'[A-Za-z0-9_]').hasMatch(src[after])) {
          continue; // 关键字边界（如 trueValue 不视为 true）
        }
        pos = after;
        return _FilterOperand.literal(
            kw == 'true' ? true : (kw == 'false' ? false : null));
      }
    }
    return null;
  }

  /// 读取引号字符串：支持 \\ 转义，允许含 ) 等任意字符；未闭合返回 null
  String? _parseString() {
    final quote = src[pos];
    pos++;
    final sb = StringBuffer();
    while (pos < src.length) {
      final c = src[pos];
      if (c == '\\' && pos + 1 < src.length) {
        pos++;
        sb.write(src[pos]);
        pos++;
      } else if (c == quote) {
        pos++;
        return sb.toString();
      } else {
        sb.write(c);
        pos++;
      }
    }
    return null; // 未闭合
  }
}

/// JS 风格真值判断（&& / || / 过滤结果的布尔化）
bool _truthy(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  return true;
}

bool _valuesEqual(dynamic a, dynamic b) {
  if (a is num && b is num) return a == b;
  if (a == null || b == null) return a == b;
  return a == b;
}

/// 顺序比较：仅数字或字符串可比，否则返回 null（比较结果为 false）
int? _order(dynamic a, dynamic b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  return null;
}

bool _compareValues(String op, dynamic left, dynamic right) {
  switch (op) {
    case '==':
      return _valuesEqual(left, right);
    case '!=':
      return !_valuesEqual(left, right);
    case '>':
      final c = _order(left, right);
      return c != null && c > 0;
    case '>=':
      final c = _order(left, right);
      return c != null && c >= 0;
    case '<':
      final c = _order(left, right);
      return c != null && c < 0;
    case '<=':
      final c = _order(left, right);
      return c != null && c <= 0;
  }
  return false;
}
