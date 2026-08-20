import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;
import 'js_template.dart';
import 'json_path.dart';
import 'rule_parser.dart';
import 'selector_engine.dart';

/// 规则执行引擎 — 支持多种规则样式从 HTML 提取数据。
///
/// 支持的规则语法：
/// 1. 单步 CSS + 属性：`div.book@href`、`h3.title`
/// 2. Legado 级联链：`class.list.0@tag.ul.0@tag.li`（多段，逐步缩小范围）
///    - 段前缀：`class.X` / `id.X` / `tag.X` / 纯 CSS
///    - 段索引：`选择器.N`（取第 N 个匹配）
/// 3. 伪属性：`@text`（取文本）、`@ownText`（取自身文本）、其他为 HTML 属性
class RuleEngine {
  static String? extractText(String html, String? rule) {
    if (rule == null || rule.isEmpty) return null;
    if (RuleParser.isJsRule(rule)) return JsTemplateEngine.extract(html, rule);
    final replace = RuleParser.replaceSuffixOf(rule);
    if (replace != null) {
      final base = extractText(html, replace.baseRule);
      return base == null ? null : SelectorEngine.applyReplaceSuffixToValue(base, replace);
    }
    if (RuleParser.isCssRule(rule)) rule = RuleParser.cssRuleOf(rule);
    if (RuleParser.isJsonPath(rule)) {
      final values = JsonPathEngine.queryString(html, RuleParser.jsonPathOf(rule));
      if (values.isEmpty) return null;
      return SelectorEngine.jsonToString(values.first);
    }
    if (RuleParser.isXPathRule(rule)) {
      final list = SelectorEngine.xpathTextList(html, rule);
      return list.isEmpty ? null : list.first;
    }
    final multi = RuleParser.multiRuleType(rule);
    if (multi == '||') {
      for (final alt in RuleParser.splitRule(rule, '||')) {
        final value = extractText(html, alt);
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }
    if (multi != null) {
      final list = extractTextList(html, rule);
      return list.isEmpty ? null : list.join('\n');
    }
    final doc = parser.parse(html);
    return _extractTextFromDoc(doc, rule);
  }

  static String? _extractTextFromDoc(dom.Document doc, String rule) {
    final parts = RuleParser.parseRule(rule);
    final elements = SelectorEngine.queryAll(doc, parts);
    if (elements.isEmpty) return null;
    return SelectorEngine.extractValue(elements.first, parts.attr);
  }

  static List<String> extractTextList(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    if (RuleParser.isJsRule(rule)) {
      final value = JsTemplateEngine.extract(html, rule);
      return value == null ? [] : [value];
    }
    final replace = RuleParser.replaceSuffixOf(rule);
    if (replace != null) {
      return [
        for (final value in extractTextList(html, replace.baseRule))
          if (SelectorEngine.applyReplaceSuffixToValue(value, replace) case final replaced?
              when replaced.isNotEmpty)
            replaced,
      ];
    }
    if (RuleParser.isCssRule(rule)) rule = RuleParser.cssRuleOf(rule);
    if (RuleParser.isJsonPath(rule)) {
      final result = <String>[];
      for (final value in JsonPathEngine.queryString(html, RuleParser.jsonPathOf(rule))) {
        if (value is List) {
          for (final item in value) {
            final text = SelectorEngine.jsonToString(item);
            if (text != null && text.isNotEmpty) result.add(text);
          }
        } else {
          final text = SelectorEngine.jsonToString(value);
          if (text != null && text.isNotEmpty) result.add(text);
        }
      }
      return result;
    }
    if (RuleParser.isXPathRule(rule)) {
      return SelectorEngine.xpathTextList(html, rule);
    }
    final multi = RuleParser.multiRuleType(rule);
    if (multi != null) {
      final parts = RuleParser.splitRule(rule, multi);
      if (multi == '||') {
        for (final part in parts) {
          final list = extractTextList(html, part);
          if (list.isNotEmpty) return list;
        }
        return [];
      }
      final lists = [
        for (final part in parts) extractTextList(html, part),
      ];
      if (multi == '%%') {
        final result = <String>[];
        if (lists.isNotEmpty) {
          for (var i = 0; i < lists.first.length; i++) {
            for (final list in lists) {
              if (i < list.length) result.add(list[i]);
            }
          }
        }
        return result;
      }
      return [for (final list in lists) ...list];
    }
    final doc = parser.parse(html);
    final parts = RuleParser.parseRule(rule);
    final elements = SelectorEngine.queryAll(doc, parts);
    return elements
        .map((e) => SelectorEngine.extractValue(e, parts.attr))
        .where((t) => t != null && t.isNotEmpty)
        .cast<String>()
        .toList();
  }

  static List<dynamic> extractElements(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    // JS 模板不子集化列表定位（bookList 级 JS 规则复杂，字段级走 getElementText）
    if (RuleParser.isJsRule(rule)) return [];
    if (RuleParser.isCssRule(rule)) rule = RuleParser.cssRuleOf(rule);
    if (RuleParser.isAllInOneRule(rule)) {
      return SelectorEngine.regexElements(html, RuleParser.allInOneOf(rule));
    }
    if (RuleParser.isJsonPath(rule)) {
      return [
        for (final value in JsonPathEngine.queryString(html, RuleParser.jsonPathOf(rule)))
          if (value is List) ...value else value,
      ];
    }
    if (RuleParser.isXPathRule(rule)) {
      return SelectorEngine.xpathElements(parser.parse(html), rule);
    }
    final multi = RuleParser.multiRuleType(rule);
    if (multi != null) {
      final parts = RuleParser.splitRule(rule, multi);
      if (multi == '||') {
        for (final part in parts) {
          final list = extractElements(html, part);
          if (list.isNotEmpty) return list;
        }
        return [];
      }
      final lists = [
        for (final part in parts) extractElements(html, part),
      ];
      final result = <dom.Element>[];
      final seen = <dom.Element>{};
      if (multi == '%%' && lists.isNotEmpty) {
        for (var i = 0; i < lists.first.length; i++) {
          for (final list in lists) {
            if (i < list.length && list[i] is dom.Element && seen.add(list[i])) {
              result.add(list[i]);
            }
          }
        }
      } else {
        for (final list in lists) {
          for (final element in list) {
            if (element is dom.Element && seen.add(element)) {
              result.add(element);
            }
          }
        }
      }
      return result;
    }
    final doc = parser.parse(html);
    final parts = RuleParser.parseRule(rule);
    return SelectorEngine.queryAll(doc, parts);
  }

  static String? getElementText(dynamic element, String? rule) {
    if (element == null || rule == null || rule.isEmpty) return null;
    if (element is List && RuleParser.needsCaptureGroup(rule)) {
      final groups = element
          .map((value) => value?.toString() ?? '')
          .toList();
      return SelectorEngine.extractFromGroups(groups, rule);
    }
    if (element is dom.Element) {
      final attrOnly =
          RegExp(r'^@([a-zA-Z][\w-]*)$').firstMatch(rule.trim());
      if (attrOnly != null) {
        return SelectorEngine.extractValue(element, attrOnly.group(1));
      }
    }
    if (RuleParser.isJsRule(rule)) {
      // 字段级 JS 规则：在元素 HTML 上下文中执行
      if (element is dom.Element) {
        return JsTemplateEngine.extract(element.outerHtml, rule);
      }
      return null;
    }
    final replace = RuleParser.replaceSuffixOf(rule);
    if (replace != null) {
      final base = getElementText(element, replace.baseRule);
      return base == null ? null : SelectorEngine.applyReplaceSuffixToValue(base, replace);
    }
    if (RuleParser.isCssRule(rule)) rule = RuleParser.cssRuleOf(rule);
    if (RuleParser.isXPathRule(rule)) {
      if (element is dom.Element) {
        final list = SelectorEngine.xpathTextList(element.outerHtml, rule);
        return list.isEmpty ? null : list.join('\n');
      }
      return null;
    }
    final multi = RuleParser.multiRuleType(rule);
    if (multi == '||') {
      for (final alt in RuleParser.splitRule(rule, '||')) {
        final value = getElementText(element, alt);
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }
    if (multi != null) {
      if (element is dom.Element) {
        final list = extractTextList(element.outerHtml, rule);
        return list.isEmpty ? null : list.join('\n');
      }
      final values = <String>[];
      for (final part in RuleParser.splitRule(rule, multi)) {
        final value = getElementText(element, part);
        if (value != null && value.isNotEmpty) values.add(value);
      }
      return values.isEmpty ? null : values.join('\n');
    }
    if (element is! dom.Element) {
      // JSON 值条目：字段规则按 JSONPath 处理
      // （支持 $.name 绝对、.name / name 相对路径）
      final normalized = RuleParser.normalizeJsonPath(rule);
      final values = JsonPathEngine.instance.query(element, RuleParser.jsonPathOf(normalized));
      if (values.isEmpty) return null;
      return SelectorEngine.jsonToString(values.first);
    }
    if (RuleParser.isJsonPath(rule)) {
      final values = JsonPathEngine.instance.query(element, RuleParser.jsonPathOf(rule));
      if (values.isEmpty) return null;
      return SelectorEngine.jsonToString(values.first);
    }
    final parts = RuleParser.parseRule(rule);
    final targets = SelectorEngine.queryAll(element, parts);
    if (targets.isEmpty) return null;
    return SelectorEngine.extractValue(targets.first, parts.attr);
  }




















  /// 规则是否 JS 模式（js 标签包裹或 at-js 前缀）
  static bool isJsRule(String rule) => RuleParser.isJsRule(rule);

  /// 在文档/元素内按规则查询元素（供 JS 模板引擎复用级联/前缀语法）
  static List<dom.Element> queryIn(dom.Node root, String rule) =>
      SelectorEngine.queryIn(root, rule);

  /// 提取元素值（伪属性 text/ownText 或 HTML 属性）
  static String? valueOf(dom.Element element, String? attr) =>
      SelectorEngine.valueOf(element, attr);













  // ---- 执行 ----













}
