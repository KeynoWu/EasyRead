import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import '../../../book_source/domain/entities/book_source.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../../search/data/engines/js_rule_executor.dart';
import '../../../search/data/engines/js_template.dart';
import '../../../search/data/engines/rule_engine.dart';
import '../../../search/data/engines/rule_template.dart';
import '../../../search/data/engines/rule_variables.dart';

/// 目录域解析工具：目录页/字段/书源信息（ruleBookInfo）解析。
/// 全部为纯静态方法，输入输出显式，便于单独测试。
class CatalogParser {
  static Future<String?> extractField(
    dynamic item,
    String? rule, {
    required String baseUrl,
    String? charset,
    Map<String, String>? variables,
    String? html,
    String? jsLib,
  }) async {
    if (rule == null || rule.isEmpty) return null;
    var normalized = rule;
    final hadGet = normalized.contains('@get:{');
    if (variables != null) {
      normalized = RuleVariables.expand(normalized, variables);
      if (normalized.contains('@put:')) {
        normalized = RuleVariables.collectAndStrip(
          normalized,
          item,
          variables,
        );
      }
    }
    rule = normalized;
    if (item is Map && hadGet && !rule.contains('{{')) {
      return rule;
    }
    if (item is Map && rule.contains('{{')) {
      final json = Map<String, dynamic>.from(item);
      var template = rule;
      if (template.contains('{{java.')) {
        template = (await JsRuleExecutor.evalTemplate(
                  template,
                  json: json,
                  html: html,
                  baseUrl: baseUrl,
                  charset: charset,
                )) ??
                template;
      }
      return RuleTemplate.interpolate(
        template,
        json: json,
        html: html,
        encodeValues: rule.contains('/') || rule.contains('?'),
      );
    }
    if (RuleEngine.isJsRule(rule)) {
      // jsLib 非空时规则体可能调用 lib 自定义函数(裸标识符)——
      // 模板子集只认 java.get 等白名单方法,自定义函数会被误判
      // canHandle=true 后走模板路径失败返回 null,必须走完整执行器
      if (jsLib == null && JsTemplateEngine.canHandle(rule)) {
        if (item is dom.Element) return RuleEngine.getElementText(item, rule);
        return JsTemplateEngine.extract(jsonEncode(item), rule);
      }
      final jsHtml = item is dom.Element ? item.outerHtml : jsonEncode(item);
      return JsRuleExecutor.execute(
        jsHtml,
        rule,
        baseUrl: baseUrl,
        charset: charset,
        variables: variables,
        jsLib: jsLib,
      );
    }
    return RuleEngine.getElementText(item, rule);
  }

  static Future<List<ChapterItem>> parseCatalogPage(
    BookSource source,
    String html,
    String baseUrl,
    Map<String, String> variables,
  ) async {
    final listRule = source.chapterListRule;
    if (listRule == null) return [];
    final List<dynamic> items;
    if (RuleEngine.isJsRule(listRule)) {
      final value = await JsRuleExecutor.execute(
        html,
        listRule,
        baseUrl: baseUrl,
        charset: source.responseCharset,
        variables: variables,
        jsLib: source.jsLib,
      );
      items = decodeJsListItems(value);
    } else {
      items = RuleEngine.extractElements(html, listRule);
    }
    final chapters = <ChapterItem>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item == null) continue;
      final itemVariables = {...variables};
      final title = await extractField(
        item,
        source.chapterNameRule,
        baseUrl: baseUrl,
        charset: source.responseCharset,
        variables: itemVariables,
        html: html,
      );
      final url = await extractField(
        item,
        source.chapterUrlRule,
        baseUrl: baseUrl,
        charset: source.responseCharset,
        variables: itemVariables,
        html: html,
      );
      if (title == null || title.isEmpty) continue;
      var finalTitle = title;
      var finalUrl = url ?? '';
      // ruleToc.formatJs：脚本内 item 含 {title, url}，可修改后返回 item。
      // 执行失败/无引擎（iOS 降级）/结果非法时按原值兜底。
      final formatJs = source.tocFormatJs;
      if (formatJs != null && formatJs.trim().isNotEmpty) {
        final formatted = await formatTocItem(
          formatJs,
          {'title': finalTitle, 'url': finalUrl},
          baseUrl: baseUrl,
          charset: source.responseCharset,
        );
        if (formatted != null) {
          final newTitle = formatted['title'];
          final newUrl = formatted['url'];
          if (newTitle != null && newTitle.isNotEmpty) finalTitle = newTitle;
          if (newUrl != null) finalUrl = newUrl;
        }
      }
      // ruleToc.isVolume：目录项求值为真则标记卷节点。
      // CSS 规则走 rule_engine 对条目元素求值（非空为真）；
      // JS 规则走 item 作用域脚本（同 formatJs 机制），结果真值标记卷头。
      // 无规则时为 null（与旧行为一致）；有规则但求值为假时为 false。
      var isVolume = false;
      final hasIsVolumeRule = source.tocIsVolumeRule != null &&
          source.tocIsVolumeRule!.trim().isNotEmpty;
      if (hasIsVolumeRule) {
        isVolume = await isVolumeItem(
          item,
          source.tocIsVolumeRule!,
          {'title': finalTitle, 'url': finalUrl},
          baseUrl: baseUrl,
          charset: source.responseCharset,
        );
      }
      chapters.add(ChapterItem(
        title: finalTitle,
        url: finalUrl,
        index: i,
        variables: Map.unmodifiable(itemVariables),
        isVolume: hasIsVolumeRule ? isVolume : null,
      ));
    }
    return chapters;
  }

  static Future<Map<String, String>?> formatTocItem(
    String rule,
    Map<String, String> item, {
    required String baseUrl,
    String? charset,
  }) async {
    final value = await JsRuleExecutor.evalItemScript(
      rule,
      item,
      baseUrl: baseUrl,
      charset: charset,
    );
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      return {
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value?.toString() ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isVolumeItem(
    dynamic item,
    String rule,
    Map<String, String> itemValues, {
    required String baseUrl,
    String? charset,
  }) async {
    if (RuleEngine.isJsRule(rule)) {
      final value = await JsRuleExecutor.evalItemScript(
        rule,
        itemValues,
        baseUrl: baseUrl,
        charset: charset,
      );
      return jsTruthy(value);
    }
    final value = RuleEngine.getElementText(item, rule);
    return value != null && value.trim().isNotEmpty;
  }

  static bool jsTruthy(String? value) {
    if (value == null) return false;
    final t = value.trim();
    if (t.isEmpty) return false;
    final lower = t.toLowerCase();
    if (lower == 'false' ||
        lower == '0' ||
        lower == 'null' ||
        lower == 'undefined' ||
        t == '""') {
      return false;
    }
    return true;
  }

  static Future<String> extractNextUrl(
    String rule,
    String html,
    String baseUrl,
    BookSource source,
    Map<String, String> variables,
  ) async {
    rule = RuleVariables.expand(rule, variables);
    final value = await extractFromPage(
      rule,
      html,
      baseUrl,
      source.responseCharset,
      variables: variables,
      jsLib: source.jsLib,
    );
    if (value == null || value.isEmpty) return '';
    return resolveUrl(
      baseUrl,
      RuleVariables.expand(value.trim(), variables),
    );
  }

  static List<dynamic> decodeJsListItems(String? value) {
    if (value == null || value.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) return decoded;
      return [decoded];
    } catch (_) {
      // 非 JSON 时按 HTML 片段处理：至少能覆盖 JS 规则直接返回单章 HTML 的场景。
      final doc = parser.parse(value);
      final body = doc.body;
      return body == null ? [] : [body];
    }
  }

  static Future<ParsedBookInfo> parseBookInfo(
    Map<String, dynamic> rules,
    String html,
    String baseUrl,
    BookSource source,
    Map<String, String> variables,
  ) async {
    dynamic jsonContext;
    try {
      final decoded = jsonDecode(html);
      if (decoded is Map || decoded is List) jsonContext = decoded;
    } catch (_) {}

    var content = html;
    final initRule = rules['init']?.toString();
    if (initRule != null && initRule.isNotEmpty) {
      final elements = RuleEngine.extractElements(html, initRule);
      if (elements.isNotEmpty && (elements.first is Map || elements.first is List)) {
        jsonContext = elements.first;
        content = jsonEncode(jsonContext);
      } else {
        final value = await extractFromPage(
          initRule,
          html,
          baseUrl,
          source.responseCharset,
          variables: variables,
        );
        if (value != null && value.isNotEmpty) {
          content = value;
          try {
            final decoded = jsonDecode(content);
            if (decoded is Map || decoded is List) jsonContext = decoded;
          } catch (_) {}
        }
      }
    }

    Future<String?> read(String key) async {
      var rule = rules[key]?.toString();
      if (rule == null || rule.trim().isEmpty) return null;
      rule = RuleVariables.expand(rule, variables);
      if (rule.contains('@put:')) {
        rule = RuleVariables.collectAndStrip(
          rule,
          jsonContext ?? content,
          variables,
        );
      }
      if (rule.contains('{{') && jsonContext is Map) {
        var template = rule;
        if (template.contains('{{java.')) {
          template = (await JsRuleExecutor.evalTemplate(
                    template,
                    json: Map<String, dynamic>.from(jsonContext),
                    html: content,
                    baseUrl: baseUrl,
                    charset: source.responseCharset,
                  )) ??
                  template;
        }
        return RuleTemplate.interpolate(
          template,
          json: Map<String, dynamic>.from(jsonContext),
          html: content,
          encodeValues: rule.contains('/') || rule.contains('?'),
        );
      }
      if (jsonContext != null) {
        final value = RuleEngine.getElementText(jsonContext, rule);
        if (value != null && value.isNotEmpty) return value;
      }
      return extractFromPage(
        rule,
        content,
        baseUrl,
        source.responseCharset,
        variables: variables,
        jsLib: source.jsLib,
      );
    }

    final tocUrl = await read('tocUrl');
    final name = await read('name');
    final author = await read('author');
    final coverUrl = await read('coverUrl');
    final intro = await read('intro');
    final kind = await read('kind');
    final lastChapter = await read('lastChapter');
    final wordCount = await read('wordCount');
    return ParsedBookInfo(
      tocUrl: tocUrl == null ? '' : resolveUrl(baseUrl, tocUrl),
      name: name,
      author: author,
      coverUrl: coverUrl == null ? null : resolveUrl(baseUrl, coverUrl),
      intro: intro,
      kind: kind,
      lastChapter: lastChapter,
      wordCount: wordCount,
    );
  }

  static Future<String?> extractFromPage(
    String rule,
    String html,
    String baseUrl,
    String? charset, {
    Map<String, String> variables = const {},
    String? jsLib,
  }) async {
    if (RuleEngine.isJsRule(rule)) {
      // jsLib 非空走完整执行器(canHandle 误判自定义函数,见 extractField)
      if (jsLib == null && JsTemplateEngine.canHandle(rule)) {
        return RuleEngine.extractText(html, rule);
      }
      return JsRuleExecutor.execute(
        html,
        rule,
        baseUrl: baseUrl,
        charset: charset,
        variables: variables,
        jsLib: jsLib,
      );
    }
    return RuleEngine.extractText(html, rule);
  }

  static String resolveUrl(String? base, String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (base == null || base.isEmpty) return path;
    try {
      return Uri.parse(base).resolve(path).toString();
    } catch (_) {
      return path;
    }
  }
}

/// ruleBookInfo 解析结果（当前只消费目录 URL，后续可扩展书名/简介等）。
class ParsedBookInfo {
  final String tocUrl;
  final String? name;
  final String? author;
  final String? coverUrl;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? wordCount;

  const ParsedBookInfo({
    required this.tocUrl,
    this.name,
    this.author,
    this.coverUrl,
    this.intro,
    this.kind,
    this.lastChapter,
    this.wordCount,
  });
}