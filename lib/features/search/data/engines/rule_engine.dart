import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;
import 'js_template.dart';
import 'json_path.dart';
import 'rule_parser.dart';
import 'selector_engine.dart';

/// 规则段归约核心（B1 重构）。
///
/// Legado 规则字符串本质上是一段"值变换管线"：JS → CSS/JsonPath/XPath
/// → `##` 替换 → 组合连接符（&&/||/%%）依次应用到输入值上。
/// 此前 extractText / extractTextList / getElementText 三入口各自实现
/// 这套分发（20 处类型判断重复），现统一为 [RulePipeline.evalString] /
/// [RulePipeline.evalStringList] 单点递归归约，三入口只保留各自的
/// 上下文语义（页面级解析 HTML / 元素级在子树查询 / 列表聚合）。

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
    return RulePipeline.evalString(html, rule);
  }


  static List<String> extractTextList(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    return RulePipeline.evalStringList(html, rule);
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
      // `##` 替换后缀优先于属性/裸字段判定（Legado：替换作用于最终值）。
      // base 规则仍以元素自身为上下文（如 '@text##a##b' 的 '@text'）。
      final replace = RuleParser.replaceSuffixOf(rule);
      if (replace != null) {
        final base = getElementText(element, replace.baseRule);
        return base == null
            ? null
            : SelectorEngine.applyReplaceSuffixToValue(base, replace);
      }
      final attrOnly =
          RegExp(r'^@([a-zA-Z][\w-]*)$').firstMatch(rule.trim());
      if (attrOnly != null) {
        return SelectorEngine.extractValue(element, attrOnly.group(1));
      }
      // Legado 裸字段规则：`text`/`ownText`/`textNodes`/`html`/`all`
      // 取元素自身值；纯属性名且元素具有该属性时取属性值
      // （如独步小说网 chapterName: 'text'、chapterUrl: 'href'）。
      // 标签名（a/ul/li 等）不是属性 → 落回通用管线。
      final bare =
          RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$').firstMatch(rule.trim());
      if (bare != null) {
        final attr = bare.group(0);
        const pseudoAttrs = {'text', 'ownText', 'textNodes', 'html', 'all'};
        if (pseudoAttrs.contains(attr) || element.attributes.containsKey(attr)) {
          return SelectorEngine.extractValue(element, attr);
        }
      }
    }
    // 通用管线：元素级先把输入序列化为其 HTML/JSON 表示
    final content = element is dom.Element ? element.outerHtml : element;
    final replaced = RulePipeline.evalString(
      content is String ? content : '',
      rule,
    );
    if (replaced != null) return replaced;
    // JSON 值条目：字段规则按 JSONPath 处理
    // （支持 $.name 绝对、.name / name 相对路径）
    if (element is! dom.Element && element is! String) {
      final normalized = RuleParser.normalizeJsonPath(rule);
      final values = JsonPathEngine.instance.query(
        element,
        RuleParser.jsonPathOf(normalized),
      );
      if (values.isEmpty) return null;
      return SelectorEngine.jsonToString(values.first);
    }
    return null;
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

/// 规则段归约核心（B1 重构）。
///
/// Legado 规则字符串本质是一段"值变换管线"：JS → CSS/JsonPath/XPath
/// → `##` 替换 → 组合连接符（&&/||/%%）依次作用到输入值。
/// 三入口（extractText / extractTextList / getElementText）共用这里的
/// 递归归约，各自只保留上下文语义（页面级 / 列表聚合 / 元素级）。
class RulePipeline {
  /// 页面级（整段 HTML）单值提取。
  static String? evalString(String html, String rule) {
    if (RuleParser.isJsRule(rule)) return JsTemplateEngine.extract(html, rule);
    final replace = RuleParser.replaceSuffixOf(rule);
    if (replace != null) {
      final base = evalString(html, replace.baseRule);
      return base == null
          ? null
          : SelectorEngine.applyReplaceSuffixToValue(base, replace);
    }
    if (RuleParser.isCssRule(rule)) rule = RuleParser.cssRuleOf(rule);
    if (RuleParser.isJsonPath(rule)) {
      final values = JsonPathEngine.queryString(
        html,
        RuleParser.jsonPathOf(rule),
      );
      if (values.isEmpty) return null;
      return SelectorEngine.jsonToString(values.first);
    }
    if (RuleParser.isXPathRule(rule)) {
      final list = SelectorEngine.xpathTextList(html, rule);
      return list.isEmpty ? null : list.first;
    }
    final multi = RuleParser.multiRuleType(rule);
    if (multi != null) {
      return evalMultiString(html, rule, multi);
    }
    final doc = parser.parse(html);
    final parts = RuleParser.parseRule(rule);
    final elements = SelectorEngine.queryAll(doc, parts);
    if (elements.isEmpty) return null;
    return SelectorEngine.extractValue(elements.first, parts.attr);
  }

  /// 页面级多值提取（列表聚合）。
  static List<String> evalStringList(String html, String rule) {
    if (RuleParser.isJsRule(rule)) {
      final value = JsTemplateEngine.extract(html, rule);
      return value == null ? [] : [value];
    }
    final replace = RuleParser.replaceSuffixOf(rule);
    if (replace != null) {
      return [
        for (final value in evalStringList(html, replace.baseRule))
          if (SelectorEngine.applyReplaceSuffixToValue(value, replace)
              case final replaced? when replaced.isNotEmpty)
            replaced,
      ];
    }
    if (RuleParser.isCssRule(rule)) rule = RuleParser.cssRuleOf(rule);
    if (RuleParser.isJsonPath(rule)) {
      final result = <String>[];
      for (final value
          in JsonPathEngine.queryString(html, RuleParser.jsonPathOf(rule))) {
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
      return evalMultiList(html, rule, multi);
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

  /// 单值上下文的组合连接符归约。
  static String? evalMultiString(String html, String rule, String multi) {
    if (multi == '||') {
      for (final alt in RuleParser.splitRule(rule, '||')) {
        final value = evalString(html, alt);
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }
    final list = evalStringList(html, rule);
    return list.isEmpty ? null : list.join('\n');
  }

  /// 列表上下文的组合连接符归约。
  static List<String> evalMultiList(String html, String rule, String multi) {
    final parts = RuleParser.splitRule(rule, multi);
    if (multi == '||') {
      for (final part in parts) {
        final list = evalStringList(html, part);
        if (list.isNotEmpty) return list;
      }
      return [];
    }
    final lists = [
      for (final part in parts) evalStringList(html, part),
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
}
