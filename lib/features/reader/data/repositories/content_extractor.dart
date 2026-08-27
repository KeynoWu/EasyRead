import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:flutter/foundation.dart' show debugPrint;
import '../../../../core/purification/purify_pattern_guard.dart';
import '../../../book_source/domain/entities/book_source.dart';
import '../../../search/data/engines/js_rule_executor.dart';
import '../../../search/data/engines/rule_engine.dart';
import '../../../search/data/engines/rule_variables.dart';
import 'catalog_parser.dart';

/// 正文域提取工具：单页正文提取/智能正文/正则替换/图片 URL 解析。
/// 全部为纯静态方法，输入输出显式，便于单独测试。
class ContentExtractor {
  /// 非可见/非正文标签：其文本不应作为正文主体候选（脚本/样式文本可能
  /// 比真正的正文容器还长，会反向选中并作为"正文"返回）。
  /// 注意：跳过的不仅是直接命中的标签本身，还要跳过其整棵子树——
  /// 正文容器内可能嵌套 script/style，Element.text 会包含其文本。
  static const Set<String> _nonContentTags = {
    'script', 'style', 'noscript', 'template',
    'svg', 'iframe', 'nav', 'header', 'footer', 'aside',
  };

  /// 元素的可见文本：DFS 收集文本节点，遇到 [_nonContentTags] 直接跳过
  /// 整棵子树。与 `Element.text` 的区别在于排除嵌套的脚本/样式文本，
  /// 防止"正文容器内嵌长 script"导致脚本文本被当作正文候选。
  static String visibleText(dom.Element element) {
    final buffer = StringBuffer();
    final stack = <dom.Node>[element];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node is dom.Text) {
        buffer.write(node.text);
      } else if (node is dom.Element) {
        if (_nonContentTags.contains(node.localName)) continue;
        for (final child in node.nodes.reversed) {
          stack.add(child);
        }
      }
    }
    return buffer.toString();
  }

  /// 智能正文提取：正文规则失配/缺失时，从页面中找出文本最多的深层
  /// 容器作为正文（跳过导航/推荐/评论等杂项）。规则提取失败时兜底，
  /// 返回原始 HTML 片段，保留段落/标题结构，由净化管线继续处理。
  static String extractMainText(String html) {
    try {
      final doc = parser.parse(html);
      final body = doc.body;
      if (body == null) return '';
      var best = '';
      dom.Element? bestElement;
      final stack = <dom.Element>[body];
      while (stack.isNotEmpty) {
        final el = stack.removeLast();
        for (final child in el.children) {
          if (_nonContentTags.contains(child.localName)) continue;
          final text = visibleText(child).trim();
          if (text.isNotEmpty && text.length > best.length) {
            best = text;
            bestElement = child;
          }
          stack.add(child);
        }
      }
      return (bestElement ?? body).innerHtml.trim();
    } catch (_) {
      return '';
    }
  }

  /// 去除正文开头与章节标题重复的标题行。
  /// 兼容正文是纯文本或 HTML 片段两种形态；仅当首个可见文本以标题开头时处理。
  static String removeRepeatedTitle(String content, String title) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty || content.trim().isEmpty) return content;
    try {
      final doc = parser.parse(content);
      final leading = doc.body?.text.trim() ?? '';
      if (leading.isEmpty || !leading.startsWith(cleanTitle)) return content;
      final escaped = RegExp.escape(cleanTitle);
      final match = RegExp(escaped, caseSensitive: false).firstMatch(content);
      if (match == null) return content;
      return (content.substring(0, match.start) + content.substring(match.end))
          .trim();
    } catch (_) {
      return content;
    }
  }

  /// 将正文 HTML 中相对路径的图片 src 解析为绝对 URL，
  /// 供阅读器图片渲染使用（data:/http(s) 原样保留）。
  static String resolveImageUrls(String html, String baseUrl) {
    if (!html.contains('<img')) return html;
    try {
      final doc = parser.parse(html);
      for (final img in doc.querySelectorAll('img')) {
        final src = img.attributes['src'] ?? '';
        if (src.isEmpty) continue;
        if (src.startsWith('http://') ||
            src.startsWith('https://') ||
            src.startsWith('data:')) {
          continue;
        }
        img.attributes['src'] = CatalogParser.resolveUrl(baseUrl, src);
      }
      return doc.body?.innerHtml ?? html;
    } catch (_) {
      return html;
    }
  }

  /// 构建内容 URL：支持 {{id}} 和直接 URL 两种方式
  static String buildContentUrl(
    String template,
    String chapterUrl,
    int index,
    String baseUrl,
  ) {
    final url = template
        .replaceAll('{{id}}', chapterUrl)
        .replaceAll('{{index}}', '$index');
    return CatalogParser.resolveUrl(baseUrl, url);
  }

  /// 提取单个正文页内容；规则失配时先走智能正文，再允许整页兜底。
  static Future<String> extractContentPage(
    BookSource source,
    String html,
    String pageUrl,
    Map<String, String> variables,
  ) async {
    var contentRule = source.chapterContentRule;
    if (contentRule != null) {
      contentRule = RuleVariables.expand(contentRule, variables);
    }
    var content = '';
    if (contentRule != null) {
      if (RuleEngine.isJsRule(contentRule)) {
        content = await JsRuleExecutor.execute(
          html,
          contentRule,
          baseUrl: pageUrl,
          charset: source.responseCharset,
          variables: variables,
        ) ??
            '';
      } else {
        content = RuleEngine.extractText(html, contentRule) ?? '';
      }
    }
    if (content.isEmpty) {
      content = extractMainText(html);
    }
    // ruleContent.subContent：主正文之后按顺序追加每个匹配子元素（HTML 片段）。
    // 无 subContent 规则或页面无匹配时行为不变。
    final subRule = source.contentSubContentRule;
    if (content.isNotEmpty &&
        subRule != null &&
        subRule.trim().isNotEmpty) {
      final subs = RuleEngine.extractElements(html, subRule);
      if (subs.isNotEmpty) {
        final buffer = StringBuffer(content);
        for (final sub in subs) {
          if (sub is dom.Element) {
            buffer.write(sub.outerHtml);
          } else if (sub is String) {
            buffer.write(sub);
          } else {
            buffer.write(jsonEncode(sub));
          }
        }
        content = buffer.toString();
      }
    }
    return content;
  }

  /// ruleContent.replaceRegex 解析与执行：
  /// JSON 数组字符串（["pattern","replacement"]）优先；
  /// 否则按 `||` 分隔（pattern||replacement）。对正文做 RegExp 全替换，
  /// 格式非法/正则失败时跳过不报错。
  static String applyContentReplaceRegex(String? rule, String content) {
    if (rule == null || rule.trim().isEmpty) return content;
    final trimmed = rule.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List && decoded.length >= 2) {
          final pattern = decoded[0]?.toString() ?? '';
          final replacement = decoded[1]?.toString() ?? '';
          return replaceAllSafe(pattern, replacement, content) ?? content;
        }
      } catch (_) {
        // 非法 JSON：降级按 || 分隔处理
      }
    }
    final sep = trimmed.indexOf('||');
    if (sep > 0) {
      final pattern = trimmed.substring(0, sep).trim();
      final replacement = trimmed.substring(sep + 2).trim();
      return replaceAllSafe(pattern, replacement, content) ?? content;
    }
    return content;
  }

  /// RegExp allMatches 全替换（支持 `$1` 捕获组引用与 `$$` 转义）；
  /// 正则非法时返回 null，由调用方跳过。
  static String? replaceAllSafe(
    String pattern,
    String replacement,
    String content,
  ) {
    try {
      // 与净化规则/选择器内联正则一致的 ReDoS 预检：书源可控 pattern 在
      // 主 isolate 同步执行，灾难性回溯会卡死阅读页
      if (PurifyPatternGuard.hasCatastrophicBacktracking(pattern)) {
        debugPrint('[ContentExtractor] 跳过有灾难性回溯风险的正则: $pattern');
        return content;
      }
      final regex = RegExp(pattern);
      final groupRef = RegExp(r'\$\$|\$\d+');
      return content.replaceAllMapped(regex, (match) {
        return replacement.replaceAllMapped(groupRef, (group) {
          if (group.group(0) == r'$$') return r'$';
          final index = int.parse(group.group(0)!.substring(1));
          return index <= match.groupCount ? (match.group(index) ?? '') : '';
        });
      });
    } catch (_) {
      return null;
    }
  }

}