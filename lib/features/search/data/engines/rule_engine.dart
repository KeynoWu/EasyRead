import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

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
    final doc = parser.parse(html);
    return _extractTextFromDoc(doc, rule);
  }

  static List<dom.Element?> extractElements(String html, String? rule) {
    if (rule == null || rule.isEmpty) return [];
    final doc = parser.parse(html);
    final parts = _parseRule(rule);
    return _queryAll(doc, parts);
  }

  static String? getElementText(dom.Element? element, String? rule) {
    if (element == null || rule == null || rule.isEmpty) return null;
    final parts = _parseRule(rule);
    final targets = _queryAll(element, parts);
    if (targets.isEmpty) return null;
    return _extractValue(targets.first, parts.attr);
  }

  // ---- 解析 ----

  static _RuleParts _parseRule(String rule) {
    final segments = rule.split('@').map((s) => s.trim()).toList();
    if (segments.length <= 1) {
      // 纯选择器（单步 CSS，可含级联段）
      return _RuleParts(selector: rule.trim());
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
    return _RuleParts(selector: rule.trim());
  }

  // ---- 执行 ----

  /// 按规则查询元素集合（支持级联链）
  /// 统一查询入口：root 为 Document 或 Element
  static List<dom.Element> _queryAll(dom.Node root, _RuleParts parts) {
    try {
      if (parts.cascadeSteps != null && parts.cascadeSteps!.isNotEmpty) {
        return _cascadeQuery(root, parts.cascadeSteps!);
      }
      if (root is dom.Document) {
        return root.querySelectorAll(parts.selector);
      }
      if (root is dom.Element) {
        return root.querySelectorAll(parts.selector);
      }
      return [];
    } catch (_) {
      // 非法选择器（用户规则错误）不崩溃，按无结果处理
      return [];
    }
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
          collected.addAll(r.querySelectorAll(step.css));
        } else if (r is dom.Element) {
          collected.addAll(r.querySelectorAll(step.css));
        }
      }
      // 去重（级联跨段可能重叠）
      final seen = <dom.Element>{};
      final unique = <dom.Element>[
        for (final e in collected)
          if (seen.add(e)) e,
      ];
      if (step.index != null) {
        // 取第 N 个 → 单元素作用域
        current = step.index! < unique.length ? [unique[step.index!]] : [];
        hasScope = true;
      } else {
        current = unique;
        hasScope = true;
      }
      if (current.isEmpty) return [];
    }
    return current;
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
      default:
        return element.attributes[attr]?.trim();
    }
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
    if (selector.contains('@')) {
      return _parseCascade(selector);
    }
    return null;
  }
}

class _CascadeStep {
  final String css;
  final int? index;

  const _CascadeStep({required this.css, this.index});
}

/// 解析级联链：`class.list.0@tag.ul.0@tag.li` → 每段 CSS + 可选索引
List<_CascadeStep> _parseCascade(String rule) {
  return rule
      .split('@')
      .map((segment) => _parseStep(segment.trim()))
      .where((s) => s != null)
      .cast<_CascadeStep>()
      .toList();
}

_CascadeStep? _parseStep(String segment) {
  if (segment.isEmpty) return null;
  var css = segment;
  int? index;

  // 索引后缀：选择器.N
  final indexMatch = RegExp(r'\.(\d+)$').firstMatch(css);
  if (indexMatch != null) {
    index = int.parse(indexMatch.group(1)!);
    css = css.substring(0, indexMatch.start);
  }
  if (css.isEmpty) return null;

  // Legado 前缀转换
  if (css.startsWith('class.')) {
    css = '.${css.substring(6)}';
  } else if (css.startsWith('id.')) {
    css = '#${css.substring(3)}';
  } else if (css.startsWith('tag.')) {
    css = css.substring(4);
  }
  return _CascadeStep(css: css, index: index);
}
