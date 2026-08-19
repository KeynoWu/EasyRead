import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/data/cookie_jar_service.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';
import '../../../../features/search/data/engines/js_rule_executor.dart';
import '../../../../features/search/data/engines/js_template.dart';
import '../../../../features/search/data/engines/rule_engine.dart';
import '../../../../features/search/data/engines/rule_template.dart';
import '../../../../features/search/data/engines/rule_variables.dart';
import '../../domain/entities/chapter.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/entities/book_detail.dart';
import '../../domain/entities/reading_progress.dart';
import '../../domain/repositories/reader_repository.dart';
import '../models/chapter_model.dart';
import '../models/reading_progress_model.dart';

/// 章节加载失败时抛出的业务异常，由 UI 转成可重试的错误态。
class ChapterLoadException implements Exception {
  final String message;

  const ChapterLoadException(this.message);

  @override
  String toString() => message;
}

class ReaderRepositoryImpl implements ReaderRepository {
  static const String localSourceId = 'local';

  final DioClient _client;
  PurifyPipeline _pipeline;
  final BookSourceRepository _sourceRepo;
  final CookieJarService _cookieJar;
  Box<ChapterModel>? _cachedChapterBox;
  Box<ReadingProgressModel>? _cachedProgressBox;
  ChapterCatalog? _cachedCatalog;
  String? _cachedCatalogKey;
  BookDetail? _lastBookDetail;
  String? _lastBookDetailKey;
  final Map<String, Map<String, String>> _variablesCache = {};

  Future<Box<ChapterModel>> _chapterBox() async =>
      _cachedChapterBox ??= await Hive.openBox<ChapterModel>(HiveBoxes.chapters);

  Future<Box<ReadingProgressModel>> _progressBox() async =>
      _cachedProgressBox ??= await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);

  ReaderRepositoryImpl({
    DioClient? client,
    PurifyPipeline? pipeline,
    BookSourceRepository? sourceRepo,
    CookieJarService? cookieJar,
  })  : _client = client ?? DioClient(),
        _pipeline = pipeline ?? PurifyPipeline(),
        _sourceRepo = sourceRepo ?? _EmptySourceRepo(),
        _cookieJar = cookieJar ?? CookieJarService();

  /// 运行时注入净化规则（用户配置加载完成后调用）
  void setPipeline(PurifyPipeline pipeline) {
    _pipeline = pipeline;
  }

  Future<BookSource?> _getSource(String sourceId) async {
    return _sourceRepo.getById(sourceId);
  }

  Future<Map<String, String>> _requestHeaders(
    BookSource source,
    String sourceId,
  ) async {
    final headers = source.requestHeaders;
    if (source.enabledCookieJar) {
      final cookie = await _cookieJar.get(sourceId);
      if (cookie != null && cookie.isNotEmpty) {
        headers.putIfAbsent('Cookie', () => cookie);
      }
    }
    return headers;
  }

  Future<String> _getStringWithLoginCheck(
    BookSource source,
    String sourceId,
    String url,
    Map<String, String> headers, {
    String? charset,
  }) async {
    final html = await _client.getString(
      url,
      headers: headers.isEmpty ? null : headers,
      sourceId: sourceId,
      charset: charset,
    );
    final loginCheckJs = source.loginCheckJs;
    if (loginCheckJs == null || loginCheckJs.trim().isEmpty) return html;

    final cookieStore = <String, String>{};
    final storedCookie = headers['Cookie'];
    if (storedCookie != null && storedCookie.isNotEmpty) {
      cookieStore[source.id] = storedCookie;
      cookieStore[source.bookSourceUrl ?? ''] = storedCookie;
      cookieStore[url] = storedCookie;
    }
    final value = await JsRuleExecutor.execute(
      html,
      loginCheckJs,
      baseUrl: url,
      charset: charset,
      cookies: cookieStore,
    );
    final updatedCookie = cookieStore[source.id] ??
        cookieStore[source.bookSourceUrl ?? ''] ??
        cookieStore[url] ??
        '';
    if (updatedCookie.isNotEmpty) {
      headers['Cookie'] = updatedCookie;
      await _cookieJar.set(sourceId, updatedCookie);
    } else if (cookieStore.containsKey(source.id) ||
        cookieStore.containsKey(source.bookSourceUrl ?? '') ||
        cookieStore.containsKey(url)) {
      headers.remove('Cookie');
      await _cookieJar.remove(sourceId);
    }
    return value != null && value.isNotEmpty ? value : html;
  }

  @override
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    Map<String, String> variables = const {},
  }) async {
    final source = await _getSource(sourceId);
    if (source == null || detailUrl.isEmpty || source.chapterListRule == null) {
      return ChapterCatalog(bookId: bookId, fetchedAt: DateTime.now());
    }

    final expandedDetailUrl = RuleVariables.expand(detailUrl, variables);
    final resolvedDetailUrl = _resolveUrl(source.bookSourceUrl, expandedDetailUrl);
    // bookUrlPattern 最小接线：不匹配仅告警，不阻塞流程
    if (!matchesBookUrlPattern(source.bookUrlPattern, resolvedDetailUrl)) {
      // 不匹配仅告警，不阻塞流程
    }
    final cacheKey =
        '${bookId}_${sourceId}_$resolvedDetailUrl|'
        '${source.chapterListRule}|${source.chapterNameRule}|'
        '${source.chapterUrlRule}|${source.loginCheckJs}|'
        '${jsonEncode(source.bookInfoRules)}|${source.nextTocUrl}|'
        '${source.tocFormatJs}|${source.tocIsVolumeRule}|'
        '${source.bookUrlPattern}|'
        '${jsonEncode(source.requestHeaders)}|${source.responseCharset}|'
        '${jsonEncode(variables)}';
    if (_cachedCatalogKey == cacheKey && _cachedCatalog != null) {
      return _cachedCatalog!;
    }

    try {
      final headers = await _requestHeaders(source, sourceId);
      final detailHtml = await _getStringWithLoginCheck(
        source,
        sourceId,
        resolvedDetailUrl,
        headers,
        charset: source.responseCharset,
      );
      var tocUrl = resolvedDetailUrl;
      var tocHtml = detailHtml;
      final infoRules = source.bookInfoRules;
      if (infoRules != null) {
        final info = await _parseBookInfo(
          infoRules,
          detailHtml,
          resolvedDetailUrl,
          source,
          variables,
        );
        if (info.tocUrl.isNotEmpty && info.tocUrl != resolvedDetailUrl) {
          tocUrl = info.tocUrl;
          tocHtml = await _getStringWithLoginCheck(
            source,
            sourceId,
            tocUrl,
            headers,
            charset: source.responseCharset,
          );
        }
        _lastBookDetail = _toBookDetail(
          bookId: bookId,
          info: info,
          fallbackName: null,
        );
        _lastBookDetailKey = '${bookId}_${sourceId}_$resolvedDetailUrl';
      }
      final chapters = <ChapterItem>[];
      var pageUrl = tocUrl;
      var pageHtml = tocHtml;
      final visited = <String>{pageUrl};
      for (var page = 0; page < 20; page++) {
        chapters.addAll(
          await _parseCatalogPage(source, pageHtml, pageUrl, variables),
        );
        final nextRule = source.nextTocUrl;
        if (nextRule == null || nextRule.trim().isEmpty) break;
        final nextUrl = await _extractNextUrl(
          nextRule,
          pageHtml,
          pageUrl,
          source,
          variables,
        );
        if (nextUrl.isEmpty || !visited.add(nextUrl)) break;
        pageUrl = nextUrl;
        pageHtml = await _getStringWithLoginCheck(
          source,
          sourceId,
          pageUrl,
          headers,
          charset: source.responseCharset,
        );
      }

      final seen = <String>{};
      final uniqueChapters = <ChapterItem>[
        for (final chapter in chapters)
          if (seen.add('${chapter.title}|${chapter.url}')) chapter,
      ];
      for (var i = 0; i < uniqueChapters.length; i++) {
        uniqueChapters[i] = ChapterItem(
          title: uniqueChapters[i].title,
          url: uniqueChapters[i].url,
          index: i,
          variables: uniqueChapters[i].variables,
          isVolume: uniqueChapters[i].isVolume,
        );
      }
      final catalog = ChapterCatalog(
        bookId: bookId,
        chapters: uniqueChapters,
        fetchedAt: DateTime.now(),
      );
      if (catalog.chapters.isNotEmpty) {
        _cachedCatalog = catalog;
        _cachedCatalogKey = cacheKey;
      }
      _variablesCache['${bookId}_${sourceId}_$resolvedDetailUrl'] =
          Map.unmodifiable(variables);
      return catalog;
    } catch (e) {
      // 目录加载失败（网络/解析）：抛错而非静默返空目录，
      // 避免上层误判"无章节"进而级联成无关的章节加载失败。
      throw const ChapterLoadException('目录加载失败');
    }
  }

  @override
  Future<BookDetail> getBookDetail({
    required String bookId,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    await getCatalog(
      bookId: bookId,
      sourceId: sourceId,
      detailUrl: detailUrl ?? '',
      variables: variables,
    );
    // key 必须与 getCatalog 内部的写入一致（expand 变量后再 resolve base）：
    // 否则带 @put 变量的详情/目录链路中 key 永远不匹配，缓存恒 miss，
    // 返回空 BookDetail 导致详情页空白。
    final key = '${bookId}_${sourceId}_${_resolveUrl(
      (await _getSource(sourceId))?.bookSourceUrl,
      RuleVariables.expand(detailUrl ?? '', variables),
    )}';
    if (_lastBookDetailKey == key && _lastBookDetail != null) {
      return _lastBookDetail!;
    }
    return BookDetail(bookId: bookId);
  }

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    var effectiveVariables = variables;
    // 缓存 key 含 sourceId 与规则指纹：换源/改规则后不会读到旧内容。
    final cacheBox = await _chapterBox();
    final source = await _getSource(sourceId);
    final cacheKey = _chapterCacheKey(
      bookId,
      sourceId,
      chapterIndex,
      source,
      detailUrl: detailUrl,
      variables: effectiveVariables,
    );
    final cached = cacheBox.get(cacheKey);
    if (cached != null) {
      // 命中时刷新缓存时间戳（限频），避免 LRU 淘汰把长期阅读的
      // 热章节误判为最旧条目
      final cachedAt = cached.cachedAt;
      if (cachedAt == null ||
          DateTime.now().difference(cachedAt) > const Duration(hours: 1)) {
        await cacheBox.put(
          cacheKey,
          ChapterModel(
            id: cached.id,
            bookId: cached.bookId,
            title: cached.title,
            content: cached.content,
            index: cached.index,
            sourceId: cached.sourceId,
            cachedAt: DateTime.now(),
          ),
        );
      }
      return cached.toEntity();
    }

    if (sourceId == localSourceId) {
      // 兼容旧版导入：旧 key 无 v3 前缀且无规则指纹。
      final legacy = cacheBox.get('${bookId}_${localSourceId}_$chapterIndex');
      if (legacy != null) return legacy.toEntity();
      throw const ChapterLoadException('书源不可用或未配置内容规则');
    }
    if (source == null) {
      throw const ChapterLoadException('书源不可用或未配置内容规则');
    }

    try {
      final resolvedDetailUrl = _resolveUrl(
        source.bookSourceUrl,
        RuleVariables.expand(detailUrl ?? '', effectiveVariables),
      );
      // 获取目录以确定章节 URL 与真实标题。目录加载失败不阻断正文：
      // 退化为正文 URL 模板 / detailUrl 兜底定位正文页。
      var chapterUrl = '';
      var chapterTitle = '';
      if (resolvedDetailUrl.isNotEmpty) {
        try {
          final catalog = await getCatalog(
            bookId: bookId,
            sourceId: sourceId,
            detailUrl: resolvedDetailUrl,
            variables: effectiveVariables,
          );
          final mergedVariables = {
            ...effectiveVariables,
            ...?_variablesCache[
                '${bookId}_${sourceId}_$resolvedDetailUrl'],
          };
          effectiveVariables = mergedVariables;
          if (chapterIndex < catalog.chapters.length) {
            chapterUrl = catalog.chapters[chapterIndex].url;
            chapterTitle = catalog.chapters[chapterIndex].title;
            effectiveVariables = {
              ...effectiveVariables,
              ...catalog.chapters[chapterIndex].variables,
            };
          }
        } on ChapterLoadException {
          // 目录加载失败：留空 chapterUrl，靠正文 URL 选择兜底
        }
      }

      // 正文页 URL 选择（Legado 语义）：
      // 1. contentUrl 模板 + 章节 URL
      // 2. contentUrl 为空时 → 目录提取的章节 URL（章节页才是正文页；
      //    相对路径基于详情页 resolve）
      // 3. 目录为空（无 chapterUrl 规则）→ 详情页兜底
      String contentUrl;
      if (source.contentUrl != null && source.contentUrl!.isNotEmpty) {
        contentUrl = RuleVariables.expand(_buildContentUrl(
          source.contentUrl!,
          chapterUrl,
          chapterIndex,
          resolvedDetailUrl,
        ), effectiveVariables);
      } else if (chapterUrl.isNotEmpty) {
        if (chapterUrl.startsWith('http')) {
          contentUrl = chapterUrl;
        } else if (resolvedDetailUrl.isNotEmpty) {
          contentUrl = _resolveUrl(resolvedDetailUrl, chapterUrl);
        } else {
          // 相对章节 URL 且无详情页可 resolve：无法定位正文页
          throw const ChapterLoadException('无法定位章节');
        }
      } else if (resolvedDetailUrl.isNotEmpty) {
        contentUrl = resolvedDetailUrl;
      } else {
        throw const ChapterLoadException('无法定位章节');
      }
      final headers = await _requestHeaders(source, sourceId);
      final html = await _getStringWithLoginCheck(
        source,
        sourceId,
        contentUrl,
        headers,
        charset: source.responseCharset,
      );

      // 提取正文（支持 nextContentUrl 分页拼接）
      final contentParts = <String>[];
      var pageUrl = contentUrl;
      var pageHtml = html;
      final visitedPages = <String>{pageUrl};
      for (var page = 0; page < 20; page++) {
        final part = await _extractContentPage(
          source,
          pageHtml,
          pageUrl,
          effectiveVariables,
        );
        if (part.isNotEmpty) contentParts.add(part);
        final nextRule = source.nextContentUrl;
        if (nextRule == null || nextRule.trim().isEmpty) break;
        final nextUrl = await _extractNextUrl(
          nextRule,
          pageHtml,
          pageUrl,
          source,
          effectiveVariables,
        );
        if (nextUrl.isEmpty || !visitedPages.add(nextUrl)) break;
        pageUrl = nextUrl;
        pageHtml = await _getStringWithLoginCheck(
          source,
          sourceId,
          pageUrl,
          headers,
          charset: source.responseCharset,
        );
      }
      var content = contentParts.join('\n');
      // 提取为空时不再整页 HTML 兜底：下面统一以 ChapterLoadException
      // 明确报错，由 UI 展示错误+重试，避免把整页 HTML 当正文
      // （"像 Web"体验的根源）。

      // ruleContent.replaceRegex：对提取的正文做正则替换。
      // 兼容 legado 格式：JSON 数组字符串 ["pattern","replacement"] 优先，
      // 否则 || 分隔（pattern||replacement）；格式非法/正则失败时跳过不报错。
      content = _applyContentReplaceRegex(source.contentReplaceRegex, content);

      // ruleContent.title：正文标题规则。先提取正文页标题，非空才覆盖
      // 章节标题（目录标题为空或与正文不一致时以此为准）。
      var effectiveTitle = chapterTitle;
      final contentTitleRule = source.contentTitleRule;
      if (contentTitleRule != null && contentTitleRule.trim().isNotEmpty) {
        final extractedTitle = await _extractFromPage(
          contentTitleRule,
          html,
          contentUrl,
          source.responseCharset,
          variables: effectiveVariables,
        );
        if (extractedTitle != null && extractedTitle.trim().isNotEmpty) {
          effectiveTitle = extractedTitle.trim();
        }
      }

      // 书名净化参数只允许使用当前书的详情，避免 _lastBookDetail 残留
      // 上一本书（无 bookInfoRules 时不更新）导致净化规则用错书名。
      final effectiveBookName =
          _lastBookDetail != null && _lastBookDetail!.bookId == bookId
              ? _lastBookDetail!.name
              : null;

      // 无论规则提取还是兜底，统一经过净化管线；否则用户正则/JS 规则
      // 在成功提取正文时会被绕过。
      content = await _pipeline.purifyAsync(
        content,
        bookName: effectiveBookName,
        sourceName: source.name,
      );
      content = resolveImageUrls(content, contentUrl);
      content = _removeRepeatedTitle(content, effectiveTitle);

      if (content.trim().isEmpty) {
        throw const ChapterLoadException('章节内容为空或解析失败，请重试或更换书源');
      }

      final rawTitle = effectiveTitle.isEmpty ? '第${chapterIndex + 1}章' : effectiveTitle;
      final title = await _pipeline.purifyTitle(
        rawTitle,
        bookName: effectiveBookName,
        sourceName: source.name,
      );
      final chapter = Chapter(
        id: cacheKey,
        bookId: bookId,
        title: title,
        content: content,
        index: chapterIndex,
        sourceId: sourceId,
        cachedAt: DateTime.now(),
      );

      await cacheBox.put(cacheKey, ChapterModel.fromEntity(chapter));
      await _trimCache(cacheBox);
      return chapter;
    } on ChapterLoadException {
      // 已含明确语义的错误（书源不可用/无法定位/内容为空）直接透传，
      // 不被兜底文案覆盖，便于用户定位问题。
      rethrow;
    } catch (_) {
      throw const ChapterLoadException('章节加载失败，请检查网络或书源规则');
    }
  }

  /// 章节缓存 key：本地书使用固定前缀；网络书源包含规则指纹，
  /// 规则/请求头变化后旧缓存自动失效。
  static String _chapterCacheKey(
    String bookId,
    String sourceId,
    int chapterIndex,
    BookSource? source,
    {
    String? detailUrl,
    Map<String, String> variables = const {},
  }
  ) {
    if (sourceId == localSourceId) {
      return 'v3_${bookId}_${localSourceId}_$chapterIndex';
    }
    final fingerprint = source == null
        ? ''
        : jsonEncode({
            'content': source.chapterContentRule,
            'contentUrl': source.contentUrl,
            'list': source.chapterListRule,
            'name': source.chapterNameRule,
            'url': source.chapterUrlRule,
            'titleRule': source.contentTitleRule,
            'subContent': source.contentSubContentRule,
            'replaceRegex': source.contentReplaceRegex,
            'loginCheckJs': source.loginCheckJs,
            'headers': source.requestHeaders,
            'charset': source.responseCharset,
            'detailUrl': detailUrl,
            'variables': variables,
          });
    final fingerprintHash = md5.convert(utf8.encode(fingerprint)).toString();
    return 'v3_${bookId}_${sourceId}_${fingerprintHash}_$chapterIndex';
  }

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
  static String _visibleText(dom.Element element) {
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
  static String _extractMainText(String html) {
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
          final text = _visibleText(child).trim();
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
  static String _removeRepeatedTitle(String content, String title) {
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

  /// 书源 bookUrlPattern 匹配判断（RegExp 语义）：不匹配仅告警、不阻塞
  /// 流程。pattern 为空或非法正则时返回 true（放行）。
  static bool matchesBookUrlPattern(String? pattern, String url) {
    if (pattern == null || pattern.trim().isEmpty) return true;
    try {
      return RegExp(pattern).hasMatch(url);
    } catch (_) {
      return true;
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
        img.attributes['src'] = _resolveUrl(baseUrl, src);
      }
      return doc.body?.innerHtml ?? html;
    } catch (_) {
      return html;
    }
  }

  /// 构建内容 URL：支持 {{id}} 和直接 URL 两种方式
  String _buildContentUrl(
    String template,
    String chapterUrl,
    int index,
    String baseUrl,
  ) {
    final url = template
        .replaceAll('{{id}}', chapterUrl)
        .replaceAll('{{index}}', '$index');
    return _resolveUrl(baseUrl, url);
  }

  /// 条目字段提取：完整 JS 规则走 quickjs，模板 JS/CSS/JSONPath 走原路径。
  Future<String?> _extractField(
    dynamic item,
    String? rule, {
    required String baseUrl,
    String? charset,
    Map<String, String>? variables,
    String? html,
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
      if (JsTemplateEngine.canHandle(rule)) {
        if (item is dom.Element) return RuleEngine.getElementText(item, rule);
        return JsTemplateEngine.extract(jsonEncode(item), rule);
      }
      final jsHtml = item is dom.Element ? item.outerHtml : jsonEncode(item);
      return JsRuleExecutor.execute(
        jsHtml,
        rule,
        baseUrl: baseUrl,
        charset: charset,
      );
    }
    return RuleEngine.getElementText(item, rule);
  }

  /// 解析单个目录页为章节列表。
  Future<List<ChapterItem>> _parseCatalogPage(
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
      );
      items = _decodeJsListItems(value);
    } else {
      items = RuleEngine.extractElements(html, listRule);
    }
    final chapters = <ChapterItem>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item == null) continue;
      final itemVariables = {...variables};
      final title = await _extractField(
        item,
        source.chapterNameRule,
        baseUrl: baseUrl,
        charset: source.responseCharset,
        variables: itemVariables,
        html: html,
      );
      final url = await _extractField(
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
        final formatted = await _formatTocItem(
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
        isVolume = await _isVolumeItem(
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

  /// 提取单个正文页内容；规则失配时先走智能正文，再允许整页兜底。
  Future<String> _extractContentPage(
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
      content = _extractMainText(html);
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

  /// 执行 ruleToc.formatJs：脚本内 item 含 {title, url}，返回修改后的
  /// {title, url}；执行失败/无引擎/结果非对象时返回 null（按原值兜底）。
  Future<Map<String, String>?> _formatTocItem(
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

  /// ruleToc.isVolume 求值：CSS 规则用 rule_engine 对目录条目求值
  /// （非空为真）；JS 规则走 item 作用域脚本（同 formatJs 机制）。
  Future<bool> _isVolumeItem(
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
      return _jsTruthy(value);
    }
    final value = RuleEngine.getElementText(item, rule);
    return value != null && value.trim().isNotEmpty;
  }

  /// JS 求值结果真值判断（legado 布尔规则语义：非空且非 false/0/null）。
  static bool _jsTruthy(String? value) {
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

  /// ruleContent.replaceRegex 解析与执行：
  /// JSON 数组字符串（["pattern","replacement"]）优先；
  /// 否则按 `||` 分隔（pattern||replacement）。对正文做 RegExp 全替换，
  /// 格式非法/正则失败时跳过不报错。
  static String _applyContentReplaceRegex(String? rule, String content) {
    if (rule == null || rule.trim().isEmpty) return content;
    final trimmed = rule.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List && decoded.length >= 2) {
          final pattern = decoded[0]?.toString() ?? '';
          final replacement = decoded[1]?.toString() ?? '';
          return _replaceAllSafe(pattern, replacement, content) ?? content;
        }
      } catch (_) {
        // 非法 JSON：降级按 || 分隔处理
      }
    }
    final sep = trimmed.indexOf('||');
    if (sep > 0) {
      final pattern = trimmed.substring(0, sep).trim();
      final replacement = trimmed.substring(sep + 2).trim();
      return _replaceAllSafe(pattern, replacement, content) ?? content;
    }
    return content;
  }

  /// RegExp allMatches 全替换（支持 `$1` 捕获组引用与 `$$` 转义）；
  /// 正则非法时返回 null，由调用方跳过。
  static String? _replaceAllSafe(
    String pattern,
    String replacement,
    String content,
  ) {
    try {
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

  /// 提取目录下一页 URL。
  Future<String> _extractNextUrl(
    String rule,
    String html,
    String baseUrl,
    BookSource source,
    Map<String, String> variables,
  ) async {
    rule = RuleVariables.expand(rule, variables);
    final value = await _extractFromPage(
      rule,
      html,
      baseUrl,
      source.responseCharset,
      variables: variables,
    );
    if (value == null || value.isEmpty) return '';
    return _resolveUrl(
      baseUrl,
      RuleVariables.expand(value.trim(), variables),
    );
  }

  /// 完整 JS 列表规则结果通常为 JSON 数组/对象；解析失败时按无结果处理。
  static List<dynamic> _decodeJsListItems(String? value) {
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

  /// 解析 Legado ruleBookInfo：先执行 init 切换内容，再读取目录 URL。
  Future<_ParsedBookInfo> _parseBookInfo(
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
        final value = await _extractFromPage(
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
      return _extractFromPage(
        rule,
        content,
        baseUrl,
        source.responseCharset,
        variables: variables,
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
    return _ParsedBookInfo(
      tocUrl: tocUrl == null ? '' : _resolveUrl(baseUrl, tocUrl),
      name: name,
      author: author,
      coverUrl: coverUrl == null ? null : _resolveUrl(baseUrl, coverUrl),
      intro: intro,
      kind: kind,
      lastChapter: lastChapter,
      wordCount: wordCount,
    );
  }

  BookDetail _toBookDetail({
    required String bookId,
    required _ParsedBookInfo info,
    String? fallbackName,
  }) {
    return BookDetail(
      bookId: bookId,
      name: info.name ?? fallbackName,
      author: info.author,
      coverUrl: info.coverUrl,
      intro: info.intro,
      kind: info.kind,
      lastChapter: info.lastChapter,
      wordCount: info.wordCount,
      tocUrl: info.tocUrl.isEmpty ? null : info.tocUrl,
    );
  }

  /// 整页级规则提取：完整 JS 走 quickjs，模板 JS/CSS/JSONPath 走原路径。
  Future<String?> _extractFromPage(
    String rule,
    String html,
    String baseUrl,
    String? charset,
    {
    Map<String, String> variables = const {},
  }
  ) async {
    if (RuleEngine.isJsRule(rule)) {
      if (JsTemplateEngine.canHandle(rule)) {
        return RuleEngine.extractText(html, rule);
      }
      return JsRuleExecutor.execute(
        html,
        rule,
        baseUrl: baseUrl,
        charset: charset,
        variables: variables,
      );
    }
    return RuleEngine.extractText(html, rule);
  }

  /// 相对路径基于详情页/书源域名 resolve；非 http(s) 或无法解析时原样返回。
  static String _resolveUrl(String? base, String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (base == null || base.isEmpty) return path;
    try {
      return Uri.parse(base).resolve(path).toString();
    } catch (_) {
      return path;
    }
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    final box = await _progressBox();
    await box.put(progress.bookId, ReadingProgressModel.fromEntity(progress));
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async {
    final box = await _progressBox();
    final model = box.get(bookId);
    return model?.toEntity();
  }

  @override
  Future<void> clearBookCache(String bookId) async {
    final box = await _chapterBox();
    final keys = box.keys.where((k) {
      final key = k as String;
      return key.startsWith('v3_${bookId}_') ||
          key.startsWith('${bookId}_${localSourceId}_');
    });
    await box.deleteAll(keys);
    // 同步失效同书的内存目录缓存：避免换源/清缓存后旧目录残留，
    // 也避免下次目录加载失败时误用上一本书的目录。
    if (_cachedCatalogKey != null &&
        _cachedCatalogKey!.startsWith('${bookId}_')) {
      _cachedCatalog = null;
      _cachedCatalogKey = null;
    }
  }

  @override
  Future<void> preloadChapters({
    required String bookId,
    required int startIndex,
    required int count,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    for (int i = 0; i < count; i++) {
      final index = startIndex + i;
      try {
        await getChapter(
          bookId: bookId,
          chapterIndex: index,
          sourceId: sourceId,
          detailUrl: detailUrl,
          variables: variables,
        );
      } catch (_) {
        // 预加载失败不阻塞当前阅读
      }
    }
  }

  /// 缓存上限控制：超过 [maxEntries] 时淘汰最旧的章节
  static const int maxEntries = 500;

  Future<void> _trimCache(Box<ChapterModel> box) async {
    if (box.length <= maxEntries) return;
    final entries = box.values.toList()
      ..sort((a, b) {
        final at = a.cachedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.cachedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return at.compareTo(bt);
      });
    final toRemove = entries.take(entries.length - maxEntries).map((e) => e.key);
    await box.deleteAll(toRemove);
  }
}

/// ruleBookInfo 解析结果（当前只消费目录 URL，后续可扩展书名/简介等）。
class _ParsedBookInfo {
  final String tocUrl;
  final String? name;
  final String? author;
  final String? coverUrl;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? wordCount;

  const _ParsedBookInfo({
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

/// 空书源仓库（无依赖注入时使用）
class _EmptySourceRepo implements BookSourceRepository {
  @override
  Future<List<BookSource>> getAll() async => [];
  @override
  Future<BookSource?> getById(String id) async => null;
  @override
  Future<void> save(BookSource source) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> importFromJson(String jsonString) async {}
  @override
  Future<void> importFromUrl(String url) async {}
  @override
  Future<List<BookSource>> getEnabled() async => [];
}
