import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

/// 规则执行引擎 — 用 CSS 选择器从 HTML 中提取数据
class RuleEngine {
  static String? extractText(String html, String? rule) {
    if (rule == null || rule.isEmpty) return null;
    final doc = parser.parse(html);
    final parts = _parseRule(rule);
    final elements = doc.querySelectorAll(parts.selector);
    if (elements.isEmpty) return null;
    return elements.first.text.trim();
  }

  static List<String> extractTextList(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    final doc = parser.parse(html);
    final parts = _parseRule(rule);
    final elements = doc.querySelectorAll(parts.selector);
    return elements.map((e) => e.text.trim()).where((t) => t.isNotEmpty).toList();
  }

  static String? extractAttr(String html, String? rule) {
    if (rule == null || rule.isEmpty) return null;
    final doc = parser.parse(html);
    final parts = _parseRule(rule);
    final elements = doc.querySelectorAll(parts.selector);
    if (elements.isEmpty) return null;
    if (parts.attr != null) {
      return elements.first.attributes[parts.attr]?.trim();
    }
    return elements.first.text.trim();
  }

  static List<dom.Element?> extractElements(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    final doc = parser.parse(html);
    return doc.querySelectorAll(rule);
  }

  static String? getElementText(dom.Element? element, String? rule) {
    if (element == null || rule == null || rule.isEmpty) return null;
    final parts = _parseRule(rule);
    final targets = element.querySelectorAll(parts.selector);
    if (targets.isEmpty) return null;
    if (parts.attr != null) {
      return targets.first.attributes[parts.attr]?.trim();
    }
    return targets.first.text.trim();
  }

  static _RuleParts _parseRule(String rule) {
    // 只按最后一个 @ 分割，避免选择器属性值内含 @（如 a[href*="@"]）被误切
    final atIndex = rule.lastIndexOf('@');
    if (atIndex > 0 && atIndex < rule.length - 1) {
      return _RuleParts(
        selector: rule.substring(0, atIndex).trim(),
        attr: rule.substring(atIndex + 1).trim(),
      );
    }
    return _RuleParts(selector: rule.trim());
  }
}

class _RuleParts {
  final String selector;
  final String? attr;
  const _RuleParts({required this.selector, this.attr});
}
