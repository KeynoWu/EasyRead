import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import '../../../../core/purification/purify_pattern_guard.dart';
import 'rule_parser.dart';

/// 选择器执行：CSS / 正则（AllInOne）/ XPath / 级联链查询与取值。
/// 规则语法解析见 [RuleParser]；本类只负责在 DOM 上执行。
class SelectorEngine {
  /// 执行 AllInOne 正则链：前面的正则逐级缩小范围，最后一个正则的每次
  /// 匹配生成一个捕获组列表（group0 为整段匹配，group1..n 为捕获组）。
  /// 正则来自用户导入的书源，为同步执行（主 isolate 无超时），
  /// 对灾难性回溯模式（ReDoS）直接拒绝，避免冻结 UI。
  static List<dynamic> regexElements(String html, String rule) {
    final patterns = RuleParser.splitRule(rule, '&&')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (patterns.isEmpty) return [];
    // 链长度上限：恶意超长链（数万条正则）本身即 DoS 载体
    if (patterns.length > 32) return [];

    var source = html;
    for (var i = 0; i < patterns.length; i++) {
      if (PurifyPatternGuard.hasCatastrophicBacktracking(patterns[i])) return [];
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

  /// 提取 XPath 文本值（支持 //tag、//tag[@class/id=...]、//tag/@attr）。
  static List<String> xpathTextList(String html, String rule) {
    final doc = parser.parse(html);
    final xpath = RuleParser.xpathOf(rule);
    final attr = RegExp(r'/@([\w-]+)$').firstMatch(xpath)?.group(1);
    final elements = SelectorEngine.xpathElements(doc, rule);
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
  static List<dom.Element> xpathElements(dom.Node root, String rule) {
    final xpath = RuleParser.xpathOf(rule)
        .replaceFirst(RegExp(r'/@[\w-]+$'), '')
        .replaceFirst(RegExp(r'/text\(\)$'), '');
    final steps = SelectorEngine.xpathSteps(xpath);
    if (steps.isEmpty) return [];
    var current = <dom.Element>[];
    for (final step in steps) {
      final roots = current.isEmpty ? <dom.Node>[root] : current;
      final next = <dom.Element>[];
      for (final r in roots) {
        final matched = step.directChild
            ? SelectorEngine.xpathDirectChildren(r, step)
            : SelectorEngine.xpathQueryAll(r, step);
        if (step.segment.index != null && matched.isNotEmpty) {
          // Legado 语义：正数从 1 计，负数从 -1（倒数）计
          final raw = step.segment.index!;
          final index = raw > 0 ? raw - 1 : matched.length + raw;
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

  static List<dom.Element> xpathQueryAll(dom.Node root, XPathStep step) {
    try {
      final css = SelectorEngine.xpathStepCss(step);
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

  static List<XPathStep> xpathSteps(String xpath) {
    final steps = <XPathStep>[];
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
        final spec = SelectorEngine.xpathSegmentSpec(sub);
        if (spec == null) return [];
        steps.add(XPathStep(directChild: i > 0, segment: spec));
      }
    }
    return steps;
  }

  static XPathSpec? xpathSegmentSpec(String segment) {
    final match = RegExp(r'^([A-Za-z][\w-]*|\*)(.*)$').firstMatch(segment);
    if (match == null) return null;
    final tag = match.group(1)!;
    var rest = match.group(2) ?? '';
    final conditions = <XPathCondition>[];
    int? index;
    int? startIndex;
    int? endIndex;
    while (rest.isNotEmpty) {
      if (!rest.startsWith('[')) return null;
      final close = rest.indexOf(']');
      if (close < 0) return null;
      final predicate = rest.substring(1, close).trim();
      rest = rest.substring(close + 1);
      if (RegExp(r'^-?\d+$').hasMatch(predicate)) {
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
        final condition = SelectorEngine.xpathCondition(rawCondition.trim());
        if (condition == null) return null;
        conditions.add(condition);
      }
    }
    return XPathSpec(
      tag: tag,
      conditions: conditions,
      index: index,
      startIndex: startIndex,
      endIndex: endIndex,
    );
  }

  static XPathCondition? xpathCondition(String condition) {
    final exists = RegExp(r'^@([\w-]+)$').firstMatch(condition);
    if (exists != null) {
      return XPathCondition(exists.group(1)!, 'exists');
    }
    final equals = RegExp(
      r"""^@([\w-]+)\s*=\s*(?:'([^']*)'|"([^"]*)")$""",
    ).firstMatch(condition);
    if (equals != null) {
      return XPathCondition(
        equals.group(1)!,
        'eq',
        equals.group(2) ?? equals.group(3),
      );
    }
    final contains = RegExp(
      r"""^contains\(\s*@([\w-]+)\s*,\s*(?:'([^']*)'|"([^"]*)")\)$""",
    ).firstMatch(condition);
    if (contains != null) {
      return XPathCondition(
        contains.group(1)!,
        'contains',
        contains.group(2) ?? contains.group(3),
      );
    }
    return null;
  }

  static String xpathStepCss(XPathStep step) {
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

  static List<dom.Element> xpathDirectChildren(
    dom.Node root,
    XPathStep step,
  ) {
    if (root is! dom.Element) return [];
    return [
      for (final child in root.children)
        if (SelectorEngine.xpathElementMatches(child, step)) child,
    ];
  }

  static bool xpathElementMatches(dom.Element element, XPathStep step) {
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

  /// 在文档/元素内按规则查询元素（供 JS 模板引擎复用级联/前缀语法）
  static List<dom.Element> queryIn(dom.Node root, String rule) {
    final normalized = RuleParser.isCssRule(rule) ? RuleParser.cssRuleOf(rule) : rule;
    return SelectorEngine.queryAll(root, RuleParser.parseRule(normalized));
  }

  /// 提取元素值（伪属性 text/ownText 或 HTML 属性）
  static String? valueOf(dom.Element element, String? attr) {
    return SelectorEngine.extractValue(element, attr);
  }

  /// JSON 值转展示文本：标量直出，对象/数组序列化
  static String? jsonToString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString();
    return jsonEncode(value);
  }

  /// 在正则捕获组列表上执行字段规则：先插值 `$0/$1/...`，再应用 `##` 替换。
  static String? extractFromGroups(List<String> groups, String rule) {
    final interpolated = rule.replaceAllMapped(
      RegExp(r'\$\d{1,2}'),
      (match) {
        final index = int.parse(match.group(0)!.substring(1));
        return index < groups.length ? groups[index] : '';
      },
    );
    return SelectorEngine.applyReplaceSuffix(interpolated);
  }

  /// Legado `##` 规则后缀：
  /// - `##regex`：删除匹配
  /// - `##regex##replacement`：替换全部匹配
  /// - `##regex##replacement###`：只处理第一个匹配
  static String? applyReplaceSuffix(String rule) {
    final suffix = RuleParser.replaceSuffixOf(rule);
    if (suffix == null) return rule.trim();
    return SelectorEngine.applyReplaceSuffixToValue(suffix.baseRule, suffix);
  }

  static String? applyReplaceSuffixToValue(
    String value,
    ReplaceSuffix suffix,
  ) {
    // 同步执行用户正则：灾难性回溯模式直接放弃替换（返回原值）
    if (PurifyPatternGuard.hasCatastrophicBacktracking(suffix.pattern)) {
      return value;
    }
    try {
      final regex = RegExp(suffix.pattern);
      if (suffix.replaceFirst) {
        final match = regex.firstMatch(value);
        // Legado/Java 语义：replaceFirst 未命中时返回原值，
        // 而不是把替换串本身当作结果（那会污染字段值）。
        if (match == null) return value;
        return SelectorEngine.expandReplacement(match, suffix.replacement);
      }
      return value.replaceAllMapped(
        regex,
        (match) => SelectorEngine.expandReplacement(match, suffix.replacement),
      );
    } catch (_) {
      return value;
    }
  }

  /// 展开 Java/Legado 风格替换串：`$1`/`$2` 引用捕获组，`$$` 转义为 `$`。
  static String expandReplacement(Match match, String replacement) {
    return replacement.replaceAllMapped(
      RegExp(r'\$\$|\$&|\$\d+'),
      (group) {
        if (group.group(0) == r'$$') return r'$';
        if (group.group(0) == r'$&') return match.group(0) ?? '';
        final index = int.parse(group.group(0)!.substring(1));
        return index <= match.groupCount ? match.group(index) ?? '' : '';
      },
    );
  }

  /// 按规则查询元素集合（支持级联链）
  /// 统一查询入口：root 为 Document 或 Element
  static List<dom.Element> queryAll(dom.Node root, RuleParts parts) {
    try {
      if (parts.cascadeSteps != null && parts.cascadeSteps!.isNotEmpty) {
        return SelectorEngine.cascadeQuery(root, parts.cascadeSteps!);
      }
      if (SelectorEngine.hasContainsPseudo(parts.selector)) {
        return SelectorEngine.queryWithContains(root, parts.selector);
      }
      return SelectorEngine.queryCss(root, parts.selector);
    } catch (_) {
      // 非法选择器（用户规则错误）不崩溃，按无结果处理
      return [];
    }
  }

  static bool hasContainsPseudo(String selector) {
    return RegExp(r':contains(?:Own)?\(').hasMatch(selector);
  }

  static List<dom.Element> queryWithContains(dom.Node root, String selector) {
    final parsed = SelectorEngine.parseContainsSelector(selector);
    if (parsed == null) return [];
    final base = parsed.$1.isEmpty ? '*' : parsed.$1;
    final conditions = parsed.$2;
    return [
      for (final element in SelectorEngine.queryCss(root, base))
        if (conditions.every((condition) => SelectorEngine.matchesContains(element, condition)))
          element,
    ];
  }

  static bool matchesContains(
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

  static (String, List<({String text, bool own})>)? parseContainsSelector(
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
      final close = RuleParser.findMatchingParen(base, open);
      if (close < 0) return null;
      final text = base.substring(open + 1, close).trim();
      if (text.isEmpty) return null;
      conditions.add((text: text, own: own));
      base = (base.substring(0, start) + base.substring(close + 1)).trim();
    }
    return conditions.isEmpty ? null : (base, conditions);
  }

  static List<dom.Element> queryCss(dom.Node root, String selector) {
    if (root is dom.Document) return root.querySelectorAll(selector);
    if (root is dom.Element) return root.querySelectorAll(selector);
    return [];
  }

  /// 级联链执行：每段在当前范围内查询并按下标裁剪，结果作为下一步作用域
  static List<dom.Element> cascadeQuery(dom.Node root, List<CascadeStep> steps) {
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
            collected.addAll(SelectorEngine.queryStep(r, step));
          }
        } else if (r is dom.Element) {
          if (step.directChildren) {
            collected.addAll(r.children);
          } else {
            collected.addAll(SelectorEngine.queryStep(r, step));
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
        final expanded = SelectorEngine.expandIndexes(unique.length, step.indexes);
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

  static List<dom.Element> queryStep(dom.Node root, CascadeStep step) {
    if (step.textQuery != null) {
      return [
        for (final element in SelectorEngine.queryCss(root, '*'))
          if (SelectorEngine.matchesContains(element, (text: step.textQuery!, own: true)))
            element,
      ];
    }
    if (SelectorEngine.hasContainsPseudo(step.css)) {
      return SelectorEngine.queryWithContains(root, step.css);
    }
    return SelectorEngine.queryCss(root, step.css);
  }

  /// 展开索引集合：整数直接保留，范围按实际列表长度生成（含负索引）。
  static List<int> expandIndexes(int length, List<Object> indexes) {
    final result = <int>[];
    for (final index in indexes) {
      if (index is int) {
        result.add(index);
      } else if (index is IndexRange) {
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
  static String? extractValue(dom.Element element, String? attr) {
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
}

/// XPath 单步（// 或 / 分隔）
class XPathStep {
  final bool directChild;
  final XPathSpec segment;

  const XPathStep({required this.directChild, required this.segment});
}

class XPathSpec {
  final String tag;
  final List<XPathCondition> conditions;
  final int? index;
  final int? startIndex;
  final int? endIndex;

  const XPathSpec({
    required this.tag,
    required this.conditions,
    this.index,
    this.startIndex,
    this.endIndex,
  });
}

class XPathCondition {
  final String attr;
  final String op;
  final String? value;

  const XPathCondition(this.attr, this.op, [this.value]);
}