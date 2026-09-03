import 'dart:convert';
import 'json_path.dart';
import 'rule_engine.dart';

/// Legado/阅读 3.0 URL 模板插值。
///
/// 支持 `{{key}}`、`{{page}}`、`{{$.json.path}}`、
/// `{{$.path || '默认值'}}` 等常见写法。JSON 字段来自搜索结果/详情页
/// 的当前条目对象，HTML 规则仍走 RuleEngine，不在本类处理。
class RuleTemplate {
  static final _template = RegExp(r'\{\{\s*(.*?)\s*\}\}');

  static String interpolate(
    String template, {
    Map<String, dynamic>? json,
    String? html,
    Map<String, String> values = const {},
    int? page,
    bool encodeValues = false,
  }) {
    // Legado `<page1,page2,...>` 翻页占位符:page 从 1 起,
    // 取第 page 段(越界取最后一段)。page 未提供(null)按第 1 页处理,
    // 避免占位符原样残留在 URL 中(与 {{page}} null→空串的旧行为对齐前,
    // 先保证 URL 可用;legado 调试/部分 explore 路径 page 即为 null)。
    var source = template;
    final effectivePage = (page != null && page > 0) ? page : 1;
    if (source.contains('<')) {
      source = source.replaceAllMapped(RegExp(r'<([^<>]*)>'), (match) {
        final pages = match.group(1)!.split(',');
        final idx = effectivePage - 1;
        final picked = idx < pages.length ? pages[idx] : pages.last;
        return picked.trim();
      });
    }
    return source.replaceAllMapped(_template, (match) {
      final expression = match.group(1)!.trim();
      final alternatives = _splitAlternatives(expression);
      for (final alt in alternatives) {
        final value = _resolve(alt, json, html, values, page);
        if (value != null && value.isNotEmpty) {
          return encodeValues ? Uri.encodeComponent(value) : value;
        }
        if (!alt.startsWith(r'$') &&
            !alt.startsWith('.') &&
            !alt.startsWith("'") &&
            !alt.startsWith('"')) {
          return encodeValues ? Uri.encodeComponent(alt) : alt;
        }
      }
      return '';
    });
  }

  static List<String> _splitAlternatives(String expression) {
    final parts = <String>[];
    var depth = 0;
    final buffer = StringBuffer();
    for (var i = 0; i < expression.length; i++) {
      final ch = expression[i];
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (ch == '|' && i + 1 < expression.length && expression[i + 1] == '|' && depth == 0) {
        parts.add(buffer.toString().trim());
        buffer.clear();
        i++;
      } else {
        buffer.write(ch);
      }
    }
    parts.add(buffer.toString().trim());
    return parts;
  }

  static String? _resolve(
    String expression,
    Map<String, dynamic>? json,
    String? html,
    Map<String, String> values,
    int? page,
  ) {
    if (expression.isEmpty) return null;
    if (expression.startsWith('@@') && html != null && html.isNotEmpty) {
      return RuleEngine.extractText(html, expression);
    }
    if (expression == 'page') return page?.toString() ?? '';
    if (values.containsKey(expression)) return values[expression];
    final arithmetic = _tryArithmetic(expression, page);
    if (arithmetic != null) return arithmetic;
    if (json == null) return null;

    var path = expression;
    if (path.startsWith("'") && path.endsWith("'") ||
        path.startsWith('"') && path.endsWith('"')) {
      return path.substring(1, path.length - 1);
    }
    if (path.toLowerCase().startsWith('@json:')) {
      path = path.substring(6).trim();
    }
    if (!path.startsWith(r'$') && !path.startsWith('.')) {
      path = '.$path';
    }
    final result = JsonPathEngine.instance.query(json, path);
    if (result.isEmpty) return null;
    final value = result.first;
    if (value == null) return null;
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString();
    return jsonEncode(value);
  }

  /// 支持 `{{(page-1)*50}}`、`{{page+1}}` 等纯四则运算模板。
  static String? _tryArithmetic(String expression, int? page) {
    if (page == null) return null;
    if (!expression.contains('page')) return null;
    final normalized = expression
        .replaceAll('page', page.toString())
        .replaceAll(RegExp(r'\s+'), '');
    if (!RegExp(r'^[\d+\-*/()]+$').hasMatch(normalized)) return null;
    try {
      final value = _ArithmeticParser(normalized).parse();
      if (value == value.roundToDouble() && value.abs() < 1e15) {
        return value.toInt().toString();
      }
      return value.toString();
    } catch (_) {
      return null;
    }
  }
}

class _ArithmeticParser {
  final String source;
  int _pos = 0;

  _ArithmeticParser(this.source);

  double parse() {
    final value = _expression();
    if (_pos != source.length) {
      throw const FormatException('unexpected token');
    }
    return value;
  }

  double _expression() {
    var value = _term();
    while (_pos < source.length) {
      final op = source[_pos];
      if (op != '+' && op != '-') break;
      _pos++;
      final rhs = _term();
      value = op == '+' ? value + rhs : value - rhs;
    }
    return value;
  }

  double _term() {
    var value = _factor();
    while (_pos < source.length) {
      final op = source[_pos];
      if (op != '*' && op != '/') break;
      _pos++;
      final rhs = _factor();
      if (op == '*') {
        value *= rhs;
      } else {
        if (rhs == 0) throw const FormatException('division by zero');
        value /= rhs;
      }
    }
    return value;
  }

  double _factor() {
    if (_pos < source.length && source[_pos] == '(') {
      _pos++;
      final value = _expression();
      if (_pos >= source.length || source[_pos] != ')') {
        throw const FormatException('missing parenthesis');
      }
      _pos++;
      return value;
    }
    final start = _pos;
    while (_pos < source.length &&
        (source[_pos].codeUnitAt(0) >= 0x30 &&
            source[_pos].codeUnitAt(0) <= 0x39)) {
      _pos++;
    }
    if (_pos == start) throw const FormatException('missing number');
    return double.parse(source.substring(start, _pos));
  }
}
