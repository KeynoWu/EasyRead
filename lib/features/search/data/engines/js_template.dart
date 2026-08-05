import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'rule_engine.dart';

/// JS 模板规则执行器（Legado 兼容，阶段 4：无 JS 引擎子集）。
///
/// 支持 `<js>...</js>` / `@js:...` 中的固定模板模式：
/// - `java.get('选择器')` / `java.get('选择器', 'text'|'href'|...)`
///   （getElement 同 get；选择器支持级联/前缀语法，复用 RuleEngine）
/// - `java.setContent(值)`：切换当前文档（值为变量或字符串）
/// - 变量赋值：`x = '字符串'` / `x = java.get(...)`
/// - 规则最终值为最后一个 java.get 的结果
///
/// 不支持的能力（返回 null，由上层标记"规则不支持"）：
/// java.ajax（同步网络）、eval、startBrowser、cookie、正则 match、
/// 循环等复杂控制流。
class JsTemplateEngine {
  static const unsupportedMarkers = [
    'java.ajax',
    'eval(',
    'startBrowser',
    'cookie.',
    '.match(',
    'for (',
    'while (',
  ];

  /// 执行 JS 模板规则，返回提取值；不支持/解析失败返回 null
  static String? extract(String html, String rawRule) {
    final body = _scriptBody(rawRule);
    if (body == null || body.trim().isEmpty) return null;
    if (unsupportedMarkers.any(body.contains)) return null;

    try {
      var doc = parser.parse(html);
      final vars = <String, String>{};
      String? lastValue;

      // 预扫描纯字符串赋值：path='class.x' / c="<span>..." 等
      final assignRe =
          RegExp("([A-Za-z_]\\w*)\\s*=\\s*('([^']*)'|\"([^\"]*)\")");
      for (final m in assignRe.allMatches(body)) {
        vars[m.group(1)!] = (m.group(3) ?? m.group(4) ?? '').toString();
      }

      // 按出现顺序提取 java.* 调用（参数支持单/双引号字面量与变量）
      final callRe = RegExp(
          "java\\.(get|getElement|setContent)\\(\\s*('([^']*)'|\"([^\"]*)\"|([A-Za-z_]\\w*))(?:,\\s*('([^']*)'|\"([^\"]*)\"))?\\s*\\)");
      var searchFrom = 0;
      while (true) {
        final match = callRe.firstMatch(body.substring(searchFrom));
        if (match == null) break;
        final call = _Call(
          method: match.group(1)!,
          arg: match.group(3) ?? match.group(4) ?? match.group(5) ?? '',
          isLiteral: match.group(3) != null || match.group(4) != null,
          attr: match.group(7) ?? match.group(8),
        );
        // 处理该调用前的赋值语句：x = java.get(...) 或 x = '...'
        final prefix = body.substring(0, searchFrom + match.start);
        final assign = RegExp(r'([A-Za-z_]\w*)\s*=\s*$').firstMatch(prefix);

        if (call.method == 'setContent') {
          doc = parser.parse(_resolveArg(call, vars));
        } else {
          final elements = RuleEngine.queryIn(doc, _resolveArg(call, vars));
          final value = _valueOfFirst(elements, call.attr);
          if (assign != null) {
            vars[assign.group(1)!] = value ?? '';
          }
          if (value != null) lastValue = value;
        }
        searchFrom += match.end;
      }

      // 无 java.get 调用但规则是纯变量/字符串：返回最后一个赋值
      if (lastValue == null) {
        final lastAssign =
            RegExp(r'([A-Za-z_]\w*)\s*=\s*(.+?)\s*;?\s*$').firstMatch(body);
        if (lastAssign != null) {
          var value = lastAssign.group(2)?.trim() ?? '';
          // 去掉包裹的引号
          if (value.length >= 2 &&
              ((value.startsWith("'") && value.endsWith("'")) ||
                  (value.startsWith('"') && value.endsWith('"')))) {
            value = value.substring(1, value.length - 1);
          }
          return value;
        }
      }
      return lastValue;
    } catch (_) {
      return null;
    }
  }

  static String _resolveArg(_Call call, Map<String, String> vars) {
    if (call.isLiteral) return call.arg;
    return vars[call.arg] ?? '';
  }

  static String? _valueOfFirst(List<dom.Element> elements, String? attr) {
    if (elements.isEmpty) return null;
    return RuleEngine.valueOf(elements.first, attr);
  }

  /// 提取脚本体：`<js>...</js>` 或 `@js:...`
  static String? _scriptBody(String rule) {
    final trimmed = rule.trim();
    if (trimmed.startsWith('<js')) {
      final start = trimmed.indexOf('>');
      final end = trimmed.lastIndexOf('</js>');
      if (start < 0) return null;
      if (end > start) return trimmed.substring(start + 1, end);
      return trimmed.substring(start + 1);
    }
    if (trimmed.startsWith('@js:')) {
      return trimmed.substring(4);
    }
    return null;
  }
}

class _Call {
  final String method;
  final String arg;
  final bool isLiteral;
  final String? attr;

  _Call({
    required this.method,
    required this.arg,
    required this.isLiteral,
    this.attr,
  });
}
