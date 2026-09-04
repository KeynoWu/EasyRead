import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:flutter/foundation.dart' show debugPrint;
import '../../../../core/purification/purify_pattern_guard.dart';
import '../../../book_source/domain/entities/book_source.dart';
import '../../../search/data/engines/js_rule_executor.dart';
import '../../../search/data/engines/rule_engine.dart';
import '../../../search/data/engines/rule_parser.dart';
import '../../../search/data/engines/rule_variables.dart';
import '../../../search/data/engines/url_spec.dart';
import '../../../search/data/engines/selector_engine.dart';
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

  /// 将正文 HTML 中的图片统一归一化（对齐 Legado HtmlFormatter.formatKeepImg
  /// 的 img 取值优先级）：src 含 `{...}` 模板/选项时拆 `,{json}` 参数（URL 部分
  /// 解析为绝对、参数原样保留）；否则优先取 data-*（懒加载占位兜底）；再退 src。
  /// data:/http(s) 原样保留，其余相对 URL 基于正文页解析为绝对 URL；
  /// img 统一重写为 `<img src="...">`（Legado 语义：去其余属性）。
  /// 注：属性值实体由 html 解析器解码（&amp;→&），无需额外反转义。
  static String resolveImageUrls(String html, String baseUrl) {
    if (!html.contains('<img')) return html;
    try {
      final doc = parser.parse(html);
      for (final img in doc.querySelectorAll('img')) {
        final attrs = img.attributes;
        final src = attrs['src'] ?? '';
        String? raw;
        var param = '';
        // 优先级 1：src 含大括号（URL 模板 / ,{json} 选项）
        if (src.contains('{')) {
          final split = UrlSpec.splitOptions(src);
          if (split != null) {
            final idx = src.indexOf(split.url);
            if (idx >= 0) {
              param = src.substring(idx + split.url.length);
              raw = split.url;
            }
          }
        }
        // 优先级 2：data-*（懒加载真实地址，取首个非空）
        raw ??= () {
          for (final entry in attrs.entries) {
            final name = entry.key.toString().toLowerCase();
            final value = entry.value.trim();
            if (name.startsWith('data-') && value.isNotEmpty) return value;
          }
          return null;
        }();
        // 优先级 3：普通 src
        raw ??= src.trim();
        if (raw.isEmpty) continue;
        var url = raw;
        if (!url.startsWith('http://') &&
            !url.startsWith('https://') &&
            !url.startsWith('data:')) {
          url = CatalogParser.resolveUrl(baseUrl, url);
        }
        attrs.clear();
        attrs['src'] = url + param;
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
    Map<String, String> variables, {
    String? cookieHeader,
  }) async {
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
          jsLib: source.jsLib,
          cookieHeader: cookieHeader,
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

  /// ruleContent.replaceRegex 执行（Legado 语义：作用于全文的完整规则，
  /// BookContent.kt:138-143 `analyzeRule.getString(replaceRegex, contentStr)`）：
  /// 1. `##` 链（主流）：`##pattern` 删除、`##pattern##replacement` 替换、
  ///    第四段非空仅首匹配（AnalyzeRule.kt:279 纯 ## 规则跳过提取只替换）；
  ///    带提取前缀时先按规则提取再替换（提取为空回退原文，防御性选择）。
  /// 2. `@js:` / `<js>` 完整 JS 规则：结果即新正文。
  /// 3. EasyRead 存量格式兼容：JSON 数组 ["pattern","replacement"]、
  ///    `pattern||replacement`（无 ## 时）。
  /// 格式非法/正则失败时跳过不报错（返回原文）。
  static Future<String> applyContentReplaceRegex(
    String? rule,
    String content, {
    String? baseUrl,
    Map<String, String>? variables,
    String? jsLib,
    String? charset,
    String? cookieHeader,
  }) async {
    if (rule == null || rule.trim().isEmpty) return content;
    final trimmed = rule.trim();
    // EasyRead 存量格式：JSON 数组 ["pattern","replacement"]
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List && decoded.length >= 2) {
          final pattern = decoded[0]?.toString() ?? '';
          final replacement = decoded[1]?.toString() ?? '';
          return replaceAllSafe(pattern, replacement, content) ?? content;
        }
      } catch (_) {
        // 非法 JSON：继续按 Legado 规则语义处理
      }
    }
    // Legado `##` 链优先于存量 `||` 分隔（## 是 Legado replaceRegex 主流形态）
    final replace = RuleParser.replaceSuffixOf(trimmed);
    if (replace != null) {
      var target = content;
      if (replace.baseRule.trim().isNotEmpty) {
        final extracted = await extractFromRule(
          replace.baseRule,
          content,
          baseUrl: baseUrl,
          variables: variables,
          jsLib: jsLib,
          charset: charset,
          cookieHeader: cookieHeader,
        );
        // 提取为空回退原文：避免把整章替换成空串
        if (extracted == null || extracted.isEmpty) return content;
        target = extracted;
      }
      return SelectorEngine.applyReplaceSuffixToValue(target, replace) ??
          content;
    }
    // 存量格式：pattern||replacement（无 ## 时保留兼容）
    final sep = trimmed.indexOf('||');
    if (sep > 0) {
      final pattern = trimmed.substring(0, sep).trim();
      final replacement = trimmed.substring(sep + 2).trim();
      return replaceAllSafe(pattern, replacement, content) ?? content;
    }
    // 完整规则（JS/选择器/JSONPath）：结果即新正文（Legado getString 语义）
    final evaluated = await extractFromRule(
      trimmed,
      content,
      baseUrl: baseUrl,
      variables: variables,
      jsLib: jsLib,
      charset: charset,
      cookieHeader: cookieHeader,
    );
    return (evaluated == null || evaluated.isEmpty) ? content : evaluated;
  }

  /// 按任意规则（JS/选择器/JSONPath）从文本中提取值
  static Future<String?> extractFromRule(
    String rule,
    String content, {
    String? baseUrl,
    Map<String, String>? variables,
    String? jsLib,
    String? charset,
    String? cookieHeader,
  }) async {
    if (RuleEngine.isJsRule(rule)) {
      return JsRuleExecutor.execute(
        content,
        rule,
        baseUrl: baseUrl,
        charset: charset,
        variables: variables ?? const {},
        jsLib: jsLib,
        cookieHeader: cookieHeader,
      );
    }
    return RuleEngine.extractText(content, rule);
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