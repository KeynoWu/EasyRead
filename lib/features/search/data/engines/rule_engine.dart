import 'dart:convert';
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;
import 'js_template.dart';
import 'json_path.dart';

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
    if (_isJsRule(rule)) return JsTemplateEngine.extract(html, rule);
    final replace = _replaceSuffixOf(rule);
    if (replace != null) {
      final base = extractText(html, replace.baseRule);
      return base == null ? null : _applyReplaceSuffixToValue(base, replace);
    }
    if (_isCssRule(rule)) rule = _cssRuleOf(rule);
    if (_isJsonPath(rule)) {
      final values = JsonPathEngine.queryString(html, _jsonPathOf(rule));
      if (values.isEmpty) return null;
      return _jsonToString(values.first);
    }
    if (_isXPathRule(rule)) {
      final list = _xpathTextList(html, rule);
      return list.isEmpty ? null : list.first;
    }
    final multi = _multiRuleType(rule);
    if (multi == '||') {
      for (final alt in _splitRule(rule, '||')) {
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
    final parts = _parseRule(rule);
    final elements = _queryAll(doc, parts);
    if (elements.isEmpty) return null;
    return _extractValue(elements.first, parts.attr);
  }

  static List<String> extractTextList(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    if (_isJsRule(rule)) {
      final value = JsTemplateEngine.extract(html, rule);
      return value == null ? [] : [value];
    }
    final replace = _replaceSuffixOf(rule);
    if (replace != null) {
      return [
        for (final value in extractTextList(html, replace.baseRule))
          if (_applyReplaceSuffixToValue(value, replace) case final replaced?
              when replaced.isNotEmpty)
            replaced,
      ];
    }
    if (_isCssRule(rule)) rule = _cssRuleOf(rule);
    if (_isJsonPath(rule)) {
      final result = <String>[];
      for (final value in JsonPathEngine.queryString(html, _jsonPathOf(rule))) {
        if (value is List) {
          for (final item in value) {
            final text = _jsonToString(item);
            if (text != null && text.isNotEmpty) result.add(text);
          }
        } else {
          final text = _jsonToString(value);
          if (text != null && text.isNotEmpty) result.add(text);
        }
      }
      return result;
    }
    if (_isXPathRule(rule)) {
      return _xpathTextList(html, rule);
    }
    final multi = _multiRuleType(rule);
    if (multi != null) {
      final parts = _splitRule(rule, multi);
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
    final parts = _parseRule(rule);
    final elements = _queryAll(doc, parts);
    return elements
        .map((e) => _extractValue(e, parts.attr))
        .where((t) => t != null && t.isNotEmpty)
        .cast<String>()
        .toList();
  }

  static String? extractAttr(String html, String? rule) {
    if (rule == null || rule.isEmpty) return null;
    final replace = _replaceSuffixOf(rule);
    if (replace != null) {
      final base = extractAttr(html, replace.baseRule);
      return base == null ? null : _applyReplaceSuffixToValue(base, replace);
    }
    final multi = _multiRuleType(rule);
    if (multi == '||') {
      for (final alt in _splitRule(rule, '||')) {
        final value = extractAttr(html, alt);
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

  static List<dynamic> extractElements(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    // JS 模板不子集化列表定位（bookList 级 JS 规则复杂，字段级走 getElementText）
    if (_isJsRule(rule)) return [];
    if (_isCssRule(rule)) rule = _cssRuleOf(rule);
    if (_isAllInOneRule(rule)) {
      return _regexElements(html, _allInOneOf(rule));
    }
    if (_isJsonPath(rule)) {
      return [
        for (final value in JsonPathEngine.queryString(html, _jsonPathOf(rule)))
          if (value is List) ...value else value,
      ];
    }
    if (_isXPathRule(rule)) {
      return _xpathElements(parser.parse(html), rule);
    }
    final multi = _multiRuleType(rule);
    if (multi != null) {
      final parts = _splitRule(rule, multi);
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
    final parts = _parseRule(rule);
    return _queryAll(doc, parts);
  }

  static String? getElementText(dynamic element, String? rule) {
    if (element == null || rule == null || rule.isEmpty) return null;
    if (element is List && _needsCaptureGroup(rule)) {
      final groups = element
          .map((value) => value?.toString() ?? '')
          .toList();
      return _extractFromGroups(groups, rule);
    }
    if (element is dom.Element) {
      final attrOnly =
          RegExp(r'^@([a-zA-Z][\w-]*)$').firstMatch(rule.trim());
      if (attrOnly != null) {
        return _extractValue(element, attrOnly.group(1));
      }
    }
    if (_isJsRule(rule)) {
      // 字段级 JS 规则：在元素 HTML 上下文中执行
      if (element is dom.Element) {
        return JsTemplateEngine.extract(element.outerHtml, rule);
      }
      return null;
    }
    final replace = _replaceSuffixOf(rule);
    if (replace != null) {
      final base = getElementText(element, replace.baseRule);
      return base == null ? null : _applyReplaceSuffixToValue(base, replace);
    }
    if (_isCssRule(rule)) rule = _cssRuleOf(rule);
    if (_isXPathRule(rule)) {
      if (element is dom.Element) {
        final list = _xpathTextList(element.outerHtml, rule);
        return list.isEmpty ? null : list.join('\n');
      }
      return null;
    }
    final multi = _multiRuleType(rule);
    if (multi == '||') {
      for (final alt in _splitRule(rule, '||')) {
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
      for (final part in _splitRule(rule, multi)) {
        final value = getElementText(element, part);
        if (value != null && value.isNotEmpty) values.add(value);
      }
      return values.isEmpty ? null : values.join('\n');
    }
    if (element is! dom.Element) {
      // JSON 值条目：字段规则按 JSONPath 处理
      // （支持 $.name 绝对、.name / name 相对路径）
      final normalized = _normalizeJsonPath(rule);
      final values = JsonPathEngine.instance.query(element, _jsonPathOf(normalized));
      if (values.isEmpty) return null;
      return _jsonToString(values.first);
    }
    if (_isJsonPath(rule)) {
      final values = JsonPathEngine.instance.query(element, _jsonPathOf(rule));
      if (values.isEmpty) return null;
      return _jsonToString(values.first);
    }
    final parts = _parseRule(rule);
    final targets = _queryAll(element, parts);
    if (targets.isEmpty) return null;
    return _extractValue(targets.first, parts.attr);
  }

  /// 相对路径规范化：`name` → `.name`（JsonPathEngine 需 . 或 [ 开头）
  static String _normalizeJsonPath(String rule) {
    final t = rule.trim();
    if (t.toLowerCase().startsWith('@json:')) return t.substring(6).trim();
    if (t.startsWith(r'$') || t.startsWith('.') || t.startsWith('[')) return t;
    return '.$t';
  }

  /// 规则是否 JSONPath 模式（$ 或 @json: 开头）
  static bool _isJsonPath(String rule) {
    final t = rule.trim();
    return t.startsWith(r'$') || t.toLowerCase().startsWith('@json:');
  }

  /// 规则是否 CSS 模式（@css: 开头）
  static bool _isCssRule(String rule) {
    final t = rule.trim();
    return t.toLowerCase().startsWith('@css:');
  }

  /// 规则是否 XPath 模式（// 或 @XPath: 开头）
  static bool _isXPathRule(String rule) {
    final t = rule.trim();
    return t.startsWith('/') || t.toLowerCase().startsWith('@xpath:');
  }

  /// 规则是否 Legado AllInOne 正则列表模式（`:正则1&&正则2`）。
  static bool _isAllInOneRule(String rule) {
    final t = rule.trim();
    return t.startsWith(':') && !_isJsRule(t);
  }

  static String _allInOneOf(String rule) => rule.trim().substring(1).trim();

  /// 执行 AllInOne 正则链：前面的正则逐级缩小范围，最后一个正则的每次
  /// 匹配生成一个捕获组列表（group0 为整段匹配，group1..n 为捕获组）。
  static List<dynamic> _regexElements(String html, String rule) {
    final patterns = _splitRule(rule, '&&')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (patterns.isEmpty) return [];

    var source = html;
    for (var i = 0; i < patterns.length; i++) {
      final RegExp regex;
      try {
        regex = RegExp(patterns[i]);
      } catch (_) {
        return [];
      }
      final matches = regex.allMatches(source).toList();
      if (i == patterns.length - 1) {
        return [
          for (final match in matches)
            [
              for (var group = 0; group <= match.groupCount; group++)
                match.group(group) ?? '',
            ],
        ];
      }
      final buffer = StringBuffer();
      for (final match in matches) {
        buffer.write(match.group(0) ?? '');
      }
      source = buffer.toString();
    }
    return [];
  }

  static String _xpathOf(String rule) {
    final t = rule.trim();
    if (t.toLowerCase().startsWith('@xpath:')) return t.substring(7).trim();
    return t;
  }

  static String _cssRuleOf(String rule) => rule.trim().substring(5).trim();

  static String _jsonPathOf(String rule) {
    final t = rule.trim();
    if (t.toLowerCase().startsWith('@json:')) return t.substring(6).trim();
    return t;
  }

  /// 提取 XPath 文本值（支持 //tag、//tag[@class/id=...]、//tag/@attr）。
  static List<String> _xpathTextList(String html, String rule) {
    final doc = parser.parse(html);
    final xpath = _xpathOf(rule);
    final attr = RegExp(r'/@([\w-]+)$').firstMatch(xpath)?.group(1);
    final elements = _xpathElements(doc, rule);
    return [
      for (final element in elements)
        if (attr != null)
          element.attributes[attr]?.trim()
        else
          element.text.trim(),
    ].whereType<String>().where((v) => v.isNotEmpty).toList();
  }

  /// 常见 XPath 子集：//tag、//tag[@class="x"]、//a[@class="x"]//span、
  /// /tag 直接子代、[@attr]、contains(@attr, "v")、[N] 位置索引。
  static List<dom.Element> _xpathElements(dom.Node root, String rule) {
    final xpath = _xpathOf(rule)
        .replaceFirst(RegExp(r'/@[\w-]+$'), '')
        .replaceFirst(RegExp(r'/text\(\)$'), '');
    final steps = _xpathSteps(xpath);
    if (steps.isEmpty) return [];
    var current = <dom.Element>[];
    for (final step in steps) {
      final roots = current.isEmpty ? <dom.Node>[root] : current;
      final next = <dom.Element>[];
      for (final r in roots) {
        final matched = step.directChild
            ? _xpathDirectChildren(r, step)
            : _xpathQueryAll(r, step);
        if (step.segment.index != null && matched.isNotEmpty) {
          final index = step.segment.index! - 1;
          if (index >= 0 && index < matched.length) {
            next.add(matched[index]);
          }
        } else {
          var selected = matched;
          if (step.segment.startIndex != null &&
              selected.length > step.segment.startIndex!) {
            selected = selected.skip(step.segment.startIndex!).toList();
          }
          if (step.segment.endIndex != null &&
              selected.length > step.segment.endIndex!) {
            selected = selected.take(step.segment.endIndex!).toList();
          }
          next.addAll(selected);
        }
      }
      current = next;
      if (current.isEmpty) return [];
    }
    return current;
  }

  static List<dom.Element> _xpathQueryAll(dom.Node root, _XPathStep step) {
    try {
      final css = _xpathStepCss(step);
      if (root is dom.Document) {
        if (css == 'html') {
          final html = root.documentElement;
          return html == null ? [] : [html];
        }
        return root.querySelectorAll(css);
      }
      if (root is dom.Element) return root.querySelectorAll(css);
    } catch (_) {}
    return [];
  }

  static List<_XPathStep> _xpathSteps(String xpath) {
    final steps = <_XPathStep>[];
    var rest = xpath.trim();
    if (rest.startsWith('/') && !rest.startsWith('//')) {
      rest = rest.substring(1);
    }
    final parts = rest.split('//');
    for (final part in parts) {
      if (part.trim().isEmpty) continue;
      final subs = part.split('/');
      for (var i = 0; i < subs.length; i++) {
        final sub = subs[i].trim();
        if (sub.isEmpty) continue;
        final spec = _xpathSegmentSpec(sub);
        if (spec == null) return [];
        steps.add(_XPathStep(directChild: i > 0, segment: spec));
      }
    }
    return steps;
  }

  static _XPathSpec? _xpathSegmentSpec(String segment) {
    final match = RegExp(r'^([A-Za-z][\w-]*|\*)(.*)$').firstMatch(segment);
    if (match == null) return null;
    final tag = match.group(1)!;
    var rest = match.group(2) ?? '';
    final conditions = <_XPathCondition>[];
    int? index;
    int? startIndex;
    int? endIndex;
    while (rest.isNotEmpty) {
      if (!rest.startsWith('[')) return null;
      final close = rest.indexOf(']');
      if (close < 0) return null;
      final predicate = rest.substring(1, close).trim();
      rest = rest.substring(close + 1);
      if (RegExp(r'^\d+$').hasMatch(predicate)) {
        index = int.parse(predicate);
        continue;
      }
      final position = RegExp(
        r'^position\(\)\s*(>=|>)\s*(\d+)$',
      ).firstMatch(predicate);
      if (position != null) {
        final n = int.parse(position.group(2)!);
        startIndex = position.group(1) == '>' ? n : n - 1;
        continue;
      }
      final positionLt = RegExp(
        r'^position\(\)\s*(<=|<)\s*(\d+)$',
      ).firstMatch(predicate);
      if (positionLt != null) {
        final n = int.parse(positionLt.group(2)!);
        endIndex = positionLt.group(1) == '<' ? n - 1 : n;
        continue;
      }
      for (final rawCondition
          in predicate.toLowerCase().split(' and ')) {
        final condition = _xpathCondition(rawCondition.trim());
        if (condition == null) return null;
        conditions.add(condition);
      }
    }
    return _XPathSpec(
      tag: tag,
      conditions: conditions,
      index: index,
      startIndex: startIndex,
      endIndex: endIndex,
    );
  }

  static _XPathCondition? _xpathCondition(String condition) {
    final exists = RegExp(r'^@([\w-]+)$').firstMatch(condition);
    if (exists != null) {
      return _XPathCondition(exists.group(1)!, 'exists');
    }
    final equals = RegExp(
      r"""^@([\w-]+)\s*=\s*(?:'([^']*)'|"([^"]*)")$""",
    ).firstMatch(condition);
    if (equals != null) {
      return _XPathCondition(
        equals.group(1)!,
        'eq',
        equals.group(2) ?? equals.group(3),
      );
    }
    final contains = RegExp(
      r"""^contains\(\s*@([\w-]+)\s*,\s*(?:'([^']*)'|"([^"]*)")\)$""",
    ).firstMatch(condition);
    if (contains != null) {
      return _XPathCondition(
        contains.group(1)!,
        'contains',
        contains.group(2) ?? contains.group(3),
      );
    }
    return null;
  }

  static String _xpathStepCss(_XPathStep step) {
    final buffer = StringBuffer(step.segment.tag);
    for (final condition in step.segment.conditions) {
      switch (condition.op) {
        case 'exists':
          buffer.write('[${condition.attr}]');
        case 'eq':
          if (condition.attr == 'class' && condition.value != null) {
            buffer.write('.${condition.value!.replaceAll(' ', '.')}');
          } else if (condition.attr == 'id' && condition.value != null) {
            buffer.write('#${condition.value}');
          } else {
            buffer.write('[${condition.attr}="${condition.value ?? ''}"]');
          }
        case 'contains':
          buffer.write('[${condition.attr}*="${condition.value ?? ''}"]');
      }
    }
    return buffer.toString();
  }

  static List<dom.Element> _xpathDirectChildren(
    dom.Node root,
    _XPathStep step,
  ) {
    if (root is! dom.Element) return [];
    return [
      for (final child in root.children)
        if (_xpathElementMatches(child, step)) child,
    ];
  }

  static bool _xpathElementMatches(dom.Element element, _XPathStep step) {
    if (step.segment.tag != '*' && element.localName != step.segment.tag) {
      return false;
    }
    for (final condition in step.segment.conditions) {
      final value = element.attributes[condition.attr];
      switch (condition.op) {
        case 'exists':
          if (value == null) return false;
        case 'eq':
          if (value != condition.value) return false;
        case 'contains':
          if (value == null || !value.contains(condition.value ?? '')) {
            return false;
          }
      }
    }
    return true;
  }

  /// 规则是否 JS 模式（js 标签包裹或 at-js 前缀）
  static bool isJsRule(String rule) => _isJsRule(rule);

  /// 规则是否 JS 模板模式（js 标签包裹或 at-js 前缀）
  static bool _isJsRule(String rule) {
    final t = rule.trim();
    return t.startsWith('<js') || t.startsWith('@js:');
  }

  /// Legado 多规则分隔符类型；JS/JSONPath 按自身语法执行。
  static String? _multiRuleType(String rule) {
    final t = rule.trim();
    if (_isJsRule(t) || _isJsonPath(t) || _isXPathRule(t)) return null;
    for (final separator in ['%%', '||', '&&']) {
      if (_splitRule(t, separator).length > 1) return separator;
    }
    return null;
  }

  /// 在文档/元素内按规则查询元素（供 JS 模板引擎复用级联/前缀语法）
  static List<dom.Element> queryIn(dom.Node root, String rule) {
    final normalized = _isCssRule(rule) ? _cssRuleOf(rule) : rule;
    return _queryAll(root, _parseRule(normalized));
  }

  /// 提取元素值（伪属性 text/ownText 或 HTML 属性）
  static String? valueOf(dom.Element element, String? attr) {
    return _extractValue(element, attr);
  }

  /// JSON 值转展示文本：标量直出，对象/数组序列化
  static String? _jsonToString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString();
    return jsonEncode(value);
  }

  /// 字段规则是否引用 AllInOne 捕获组或带 `##` 替换后缀。
  static bool _needsCaptureGroup(String rule) {
    return rule.contains('##') || RegExp(r'\$\d{1,2}').hasMatch(rule);
  }

  /// 在正则捕获组列表上执行字段规则：先插值 `$0/$1/...`，再应用 `##` 替换。
  static String? _extractFromGroups(List<String> groups, String rule) {
    final interpolated = rule.replaceAllMapped(
      RegExp(r'\$\d{1,2}'),
      (match) {
        final index = int.parse(match.group(0)!.substring(1));
        return index < groups.length ? groups[index] : '';
      },
    );
    return _applyReplaceSuffix(interpolated);
  }

  /// Legado `##` 规则后缀：
  /// - `##regex`：删除匹配
  /// - `##regex##replacement`：替换全部匹配
  /// - `##regex##replacement###`：只处理第一个匹配
  static String? _applyReplaceSuffix(String rule) {
    final suffix = _replaceSuffixOf(rule);
    if (suffix == null) return rule.trim();
    return _applyReplaceSuffixToValue(suffix.baseRule, suffix);
  }

  static _ReplaceSuffix? _replaceSuffixOf(String rule) {
    final index = rule.indexOf('##');
    if (index < 0) return null;
    final baseRule = rule.substring(0, index).trim();
    final parts = rule.substring(index).split('##');
    if (parts.length < 2) return null;
    return _ReplaceSuffix(
      baseRule: baseRule,
      pattern: parts[1],
      replacement: parts.length > 2 ? parts[2] : '',
      replaceFirst: parts.length > 3,
    );
  }

  static String? _applyReplaceSuffixToValue(
    String value,
    _ReplaceSuffix suffix,
  ) {
    try {
      final regex = RegExp(suffix.pattern);
      if (suffix.replaceFirst) {
        final match = regex.firstMatch(value);
        if (match == null) return suffix.replacement;
        return _expandReplacement(match, suffix.replacement);
      }
      return value.replaceAllMapped(
        regex,
        (match) => _expandReplacement(match, suffix.replacement),
      );
    } catch (_) {
      return value;
    }
  }

  /// 展开 Java/Legado 风格替换串：`$1`/`$2` 引用捕获组，`$$` 转义为 `$`。
  static String _expandReplacement(Match match, String replacement) {
    return replacement.replaceAllMapped(
      RegExp(r'\$\$|\$\d+'),
      (group) {
        if (group.group(0) == r'$$') return r'$';
        final index = int.parse(group.group(0)!.substring(1));
        return index <= match.groupCount ? match.group(index) ?? '' : '';
      },
    );
  }

  // ---- 解析 ----

  static _RuleParts _parseRule(String rule) {
    var normalized = rule.trim();
    // Legado `@@`：转义首个 @，避免空首段被当作级联起点
    if (normalized.startsWith('@@')) {
      normalized = normalized.substring(2);
    }
    final segments = _splitRule(normalized, '@')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length <= 1) {
      // 纯选择器（单步 CSS，可含级联段）
      return _RuleParts(selector: normalized);
    }

    // 最后一段是纯标识符 → 视为属性提取（如 href / src / text / ownText）
    final last = segments.last;
    final isAttr = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$').hasMatch(last);
    if (isAttr) {
      return _RuleParts(
        selector: segments.sublist(0, segments.length - 1).join('@'),
        attr: last,
      );
    }
    // 否则整体为级联链（含多段选择器）
    return _RuleParts(selector: normalized);
  }

  // ---- 执行 ----

  /// 按规则查询元素集合（支持级联链）
  /// 统一查询入口：root 为 Document 或 Element
  static List<dom.Element> _queryAll(dom.Node root, _RuleParts parts) {
    try {
      if (parts.cascadeSteps != null && parts.cascadeSteps!.isNotEmpty) {
        return _cascadeQuery(root, parts.cascadeSteps!);
      }
      if (_hasContainsPseudo(parts.selector)) {
        return _queryWithContains(root, parts.selector);
      }
      return _queryCss(root, parts.selector);
    } catch (_) {
      // 非法选择器（用户规则错误）不崩溃，按无结果处理
      return [];
    }
  }

  static bool _hasContainsPseudo(String selector) {
    return RegExp(r':contains(?:Own)?\(').hasMatch(selector);
  }

  static List<dom.Element> _queryWithContains(dom.Node root, String selector) {
    final parsed = _parseContainsSelector(selector);
    if (parsed == null) return [];
    final base = parsed.$1.isEmpty ? '*' : parsed.$1;
    final conditions = parsed.$2;
    return [
      for (final element in _queryCss(root, base))
        if (conditions.every((condition) => _matchesContains(element, condition)))
          element,
    ];
  }

  static bool _matchesContains(
    dom.Element element,
    ({String text, bool own}) condition,
  ) {
    final haystack = condition.own
        ? [
            for (final node in element.nodes)
              if (node is dom.Text) node.text,
          ].join()
        : element.text;
    return haystack.toLowerCase().contains(condition.text.toLowerCase());
  }

  static (String, List<({String text, bool own})>)? _parseContainsSelector(
    String selector,
  ) {
    var base = selector;
    final conditions = <({String text, bool own})>[];
    while (true) {
      final start = base.indexOf(':contains');
      if (start < 0) break;
      final own = base.startsWith(':containsOwn', start);
      final prefixLength = own ? 12 : 9;
      final open = base.indexOf('(', start);
      if (open != start + prefixLength) return null;
      final close = _findMatchingParen(base, open);
      if (close < 0) return null;
      final text = base.substring(open + 1, close).trim();
      if (text.isEmpty) return null;
      conditions.add((text: text, own: own));
      base = (base.substring(0, start) + base.substring(close + 1)).trim();
    }
    return conditions.isEmpty ? null : (base, conditions);
  }

  static int _findMatchingParen(String value, int open) {
    var depth = 0;
    for (var i = open; i < value.length; i++) {
      if (value[i] == '(') {
        depth++;
      } else if (value[i] == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static List<dom.Element> _queryCss(dom.Node root, String selector) {
    if (root is dom.Document) return root.querySelectorAll(selector);
    if (root is dom.Element) return root.querySelectorAll(selector);
    return [];
  }

  /// 级联链执行：每段在当前范围内查询并按下标裁剪，结果作为下一步作用域
  static List<dom.Element> _cascadeQuery(dom.Node root, List<_CascadeStep> steps) {
    var current = <dom.Element>[];
    var hasScope = false;

    for (final step in steps) {
      final queryRoots = hasScope ? current : [root];
      final collected = <dom.Element>[];
      for (final r in queryRoots) {
        if (r is dom.Document) {
          if (step.directChildren) {
            collected.addAll(r.children.whereType<dom.Element>());
          } else {
            collected.addAll(_queryStep(r, step));
          }
        } else if (r is dom.Element) {
          if (step.directChildren) {
            collected.addAll(r.children);
          } else {
            collected.addAll(_queryStep(r, step));
          }
        }
      }
      // 去重（级联跨段可能重叠）
      final seen = <dom.Element>{};
      final unique = <dom.Element>[
        for (final e in collected)
          if (seen.add(e)) e,
      ];
      if (step.indexes.isNotEmpty) {
        final expanded = _expandIndexes(unique.length, step.indexes);
        if (step.exclude) {
          final selected = <dom.Element>{};
          for (final rawIndex in expanded) {
            final index = rawIndex < 0 ? unique.length + rawIndex : rawIndex;
            if (index >= 0 && index < unique.length) {
              selected.add(unique[index]);
            }
          }
          current = [
            for (final e in unique)
              if (!selected.contains(e)) e,
          ];
        } else {
          final seen = <dom.Element>{};
          current = [];
          for (final rawIndex in expanded) {
            final index = rawIndex < 0 ? unique.length + rawIndex : rawIndex;
            if (index >= 0 &&
                index < unique.length &&
                seen.add(unique[index])) {
              current.add(unique[index]);
            }
          }
        }
        hasScope = true;
      } else {
        current = unique;
        hasScope = true;
      }
      if (current.isEmpty) return [];
    }
    return current;
  }

  static List<dom.Element> _queryStep(dom.Node root, _CascadeStep step) {
    if (step.textQuery != null) {
      return [
        for (final element in _queryCss(root, '*'))
          if (_matchesContains(element, (text: step.textQuery!, own: true)))
            element,
      ];
    }
    if (_hasContainsPseudo(step.css)) {
      return _queryWithContains(root, step.css);
    }
    return _queryCss(root, step.css);
  }

  /// 展开索引集合：整数直接保留，范围按实际列表长度生成（含负索引）。
  static List<int> _expandIndexes(int length, List<Object> indexes) {
    final result = <int>[];
    for (final index in indexes) {
      if (index is int) {
        result.add(index);
      } else if (index is _IndexRange) {
        var start = index.start;
        var end = index.end;
        if (start < 0) start += length;
        if (end < 0) end += length;
        start = start.clamp(0, length - 1);
        end = end.clamp(0, length - 1);
        if (index.reverse) {
          for (var i = length - 1; i >= 0; i--) {
            result.add(i);
          }
        } else if (index.step > 0) {
          for (var i = start; i <= end; i += index.step) {
            result.add(i);
          }
        } else {
          for (var i = start; i >= end; i += index.step) {
            result.add(i);
          }
        }
      }
    }
    return result;
  }

  /// 提取值：伪属性（text/ownText）与 HTML 属性
  static String? _extractValue(dom.Element element, String? attr) {
    if (attr == null) return element.text.trim();
    switch (attr) {
      case 'text':
        return element.text.trim();
      case 'ownText':
        final buffer = StringBuffer();
        for (final node in element.nodes) {
          if (node is dom.Text) buffer.write(node.text);
        }
        return buffer.toString().trim();
      case 'textNodes':
        final texts = <String>[];
        for (final node in element.nodes) {
          if (node is dom.Text && node.text.trim().isNotEmpty) {
            texts.add(node.text.trim());
          }
        }
        return texts.isEmpty ? null : texts.join('\n');
      case 'html':
        // Legado 语义：移除 script/style 后返回元素 HTML。
        final clone = element.clone(true);
        for (final tag in ['script', 'style']) {
          clone.querySelectorAll(tag).forEach((e) => e.remove());
        }
        return clone.outerHtml.trim();
      case 'all':
        return element.outerHtml.trim();
      default:
        return element.attributes[attr]?.trim();
    }
  }

  /// 按分隔符拆分规则，忽略引号与 CSS 属性选择器括号内的分隔符。
  /// 例如 `a[href*="@"]` 不会被拆坏，`class.list@tag.li` 仍按级联拆分。
  static List<String> _splitRule(String rule, String separator) {
    if (separator.isEmpty || !rule.contains(separator)) return [rule];
    final parts = <String>[];
    final buffer = StringBuffer();
    var bracketDepth = 0;
    var parenDepth = 0;
    String? quote;

    for (var i = 0; i < rule.length; i++) {
      final ch = rule[i];
      if (quote != null) {
        buffer.write(ch);
        if (ch == r'\' && i + 1 < rule.length) {
          buffer.write(rule[++i]);
        } else if (ch == quote) {
          quote = null;
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        buffer.write(ch);
        continue;
      }
      if (ch == '[') {
        bracketDepth++;
        buffer.write(ch);
        continue;
      }
      if (ch == ']' && bracketDepth > 0) {
        bracketDepth--;
        buffer.write(ch);
        continue;
      }
      if (ch == '(') {
        parenDepth++;
        buffer.write(ch);
        continue;
      }
      if (ch == ')' && parenDepth > 0) {
        parenDepth--;
        buffer.write(ch);
        continue;
      }
      if (bracketDepth == 0 && parenDepth == 0 && rule.startsWith(separator, i)) {
        parts.add(buffer.toString().trim());
        buffer.clear();
        i += separator.length - 1;
        continue;
      }
      buffer.write(ch);
    }
    parts.add(buffer.toString().trim());
    return parts;
  }

  /// 供级联解析复用的 @ 分隔逻辑（与规则解析保持一致）。
  static List<String> _splitRuleForCascade(String rule) {
    return _splitRule(rule, '@');
  }
}

class _RuleParts {
  final String selector;

  /// 级联步骤（selector 为多段 @ 连接时解析）
  final List<_CascadeStep>? _cascade;
  final String? attr;

  const _RuleParts({required this.selector, this.attr}) : _cascade = null;

  List<_CascadeStep>? get cascadeSteps {
    if (_cascade != null) return _cascade;
    // 缓存解析结果：搜索结果循环中同一字段规则被每条目重复访问
    final cached = _cascadeCache[selector];
    if (cached != null) return cached.isEmpty ? null : cached;
    final steps = _parseCascade(selector);
    _cascadeCache[selector] = steps;
    return steps.isEmpty ? null : steps;
  }
}

/// 级联解析缓存（规则字符串有限，防每次查询重复解析）
final Map<String, List<_CascadeStep>> _cascadeCache = {};

class _CascadeStep {
  final String css;
  final List<Object> indexes;
  final bool exclude;
  final bool directChildren;
  final String? textQuery;

  const _CascadeStep({
    required this.css,
    this.indexes = const [],
    this.exclude = false,
    this.directChildren = false,
    this.textQuery,
  });
}

class _IndexRange {
  final int start;
  final int end;
  final int step;
  final bool reverse;

  const _IndexRange({
    required this.start,
    required this.end,
    required this.step,
    this.reverse = false,
  });
}

class _XPathStep {
  final bool directChild;
  final _XPathSpec segment;

  const _XPathStep({required this.directChild, required this.segment});
}

class _XPathSpec {
  final String tag;
  final List<_XPathCondition> conditions;
  final int? index;
  final int? startIndex;
  final int? endIndex;

  const _XPathSpec({
    required this.tag,
    required this.conditions,
    this.index,
    this.startIndex,
    this.endIndex,
  });
}

class _XPathCondition {
  final String attr;
  final String op;
  final String? value;

  const _XPathCondition(this.attr, this.op, [this.value]);
}

class _ReplaceSuffix {
  final String baseRule;
  final String pattern;
  final String replacement;
  final bool replaceFirst;

  const _ReplaceSuffix({
    required this.baseRule,
    required this.pattern,
    required this.replacement,
    required this.replaceFirst,
  });
}

/// 解析级联链：`class.list.0@tag.ul.0@tag.li` → 每段 CSS + 可选索引
List<_CascadeStep> _parseCascade(String rule) {
  return RuleEngine._splitRuleForCascade(rule)
      .map((segment) => _parseStep(segment.trim()))
      .where((s) => s != null)
      .cast<_CascadeStep>()
      .toList();
}

_CascadeStep? _parseStep(String segment) {
  if (segment.isEmpty) return null;
  var css = segment;
  final indexes = <Object>[];
  var exclude = false;
  var directChildren = false;

  // `[]` 索引写法：tag.li[0,2]、tag.li[!0,2]、tag.li[0:2]、tag.li[-1:0]
  if (css.endsWith(']')) {
    final open = css.lastIndexOf('[');
    if (open > 0) {
      var indexBody = css.substring(open + 1, css.length - 1).trim();
      if (indexBody.startsWith('!')) {
        exclude = true;
        indexBody = indexBody.substring(1).trim();
      }
      final parsed = _parseIndexSet(indexBody);
      if (parsed != null) {
        indexes.addAll(parsed);
        css = css.substring(0, open).trim();
      }
    }
  }

  // children 直接子元素前缀：children.0 / children!0:2
  if (!directChildren && css.startsWith('children')) {
    directChildren = true;
    final rest = css.substring('children'.length);
    final childrenIndexes = _parseLegacyIndexes(rest);
    if (childrenIndexes != null) {
      indexes.addAll(childrenIndexes.$1);
      exclude = childrenIndexes.$2;
      css = '';
    } else if (rest.isEmpty) {
      css = '';
    } else {
      // children.class.x 等复杂写法暂不识别，退回普通 CSS
      directChildren = false;
    }
  }

  // text.xxx 前缀：匹配自身文本包含 xxx 的元素（Legado getElementsContainingOwnText）
  if (css.startsWith('text.')) {
    final text = css.substring(5);
    if (text.isEmpty) return null;
    return _CascadeStep(
      css: '*',
      textQuery: text,
      indexes: indexes,
      exclude: exclude,
    );
  }

  // 旧式索引后缀：tag.li.0 / tag.li.-1 / tag.li.0:2 / tag.li!0
  if (css.isNotEmpty) {
    final indexMatch = RegExp(
      r'^(class\.|id\.|tag\.)(.*?)([.!])(-?\d+(?::-?\d+)*)$',
    ).firstMatch(css);
    if (indexMatch != null) {
      final parsed = _parseLegacyIndexes(
        '${indexMatch.group(3)}${indexMatch.group(4)}',
      );
      if (parsed != null) {
        indexes.addAll(parsed.$1);
        exclude = parsed.$2;
        css = '${indexMatch.group(1)}${indexMatch.group(2)}';
      }
    }
  }

  // 索引后缀仅对 Legado 前缀形式生效（class./id./tag.）：
  // 避免误伤纯 CSS 类名（如 .item2 是类名而非索引）
  if (css.isEmpty && !directChildren) return null;

  // Legado 前缀转换
  if (css.startsWith('class.')) {
    css = '.${css.substring(6)}';
  } else if (css.startsWith('id.')) {
    css = '#${css.substring(3)}';
  } else if (css.startsWith('tag.')) {
    css = css.substring(4);
  }
  return _CascadeStep(
    css: css,
    indexes: indexes,
    exclude: exclude,
    directChildren: directChildren,
  );
}

/// 解析旧式索引串：`.0` / `.0:2` / `!0` / `!-1:2`。
(List<Object>, bool)? _parseLegacyIndexes(String suffix) {
  if (suffix.isEmpty) return null;
  final separator = suffix[0];
  if (separator != '.' && separator != '!') return null;
  final indexBody = suffix.substring(1);
  if (!RegExp(r'^-?\d+(?::-?\d+)*$').hasMatch(indexBody)) return null;
  return (
    [for (final part in indexBody.split(':')) int.parse(part)],
    separator == '!',
  );
}

/// 解析 `[]` 索引集合：数字、`start:end`、`start:end:step`、`-1:0` 反向。
List<Object>? _parseIndexSet(String body) {
  if (body.isEmpty) return null;
  final result = <Object>[];
  for (final raw in body.split(',')) {
    final item = raw.trim();
    if (item.isEmpty) continue;
    if (RegExp(r'^-?\d+$').hasMatch(item)) {
      result.add(int.parse(item));
      continue;
    }
    final range =
        RegExp(r'^(-?\d+):(-?\d+)(?::(-?\d+))?$').firstMatch(item);
    if (range != null) {
      final start = int.parse(range.group(1)!);
      final end = int.parse(range.group(2)!);
      final step = range.group(3) == null ? 1 : int.parse(range.group(3)!);
      result.add(_IndexRange(
        start: start,
        end: end,
        step: step,
        reverse: start == -1 && end == 0 && step == 1,
      ));
      continue;
    }
    return null;
  }
  return result;
}
