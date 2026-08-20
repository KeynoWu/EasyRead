import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/data/cookie_jar_service.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';
import '../../../../features/search/data/engines/js_rule_executor.dart';
import '../../../../features/search/data/engines/rule_variables.dart';
import '../../domain/entities/chapter.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/entities/book_detail.dart';
import '../../domain/entities/reading_progress.dart';
import '../../domain/repositories/reader_repository.dart';
import '../models/chapter_model.dart';
import '../models/reading_progress_model.dart';
import 'catalog_parser.dart';
import 'content_extractor.dart';

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
    final resolvedDetailUrl = CatalogParser.resolveUrl(source.bookSourceUrl, expandedDetailUrl);
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
        final info = await CatalogParser.parseBookInfo(
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
          await CatalogParser.parseCatalogPage(source, pageHtml, pageUrl, variables),
        );
        final nextRule = source.nextTocUrl;
        if (nextRule == null || nextRule.trim().isEmpty) break;
        final nextUrl = await CatalogParser.extractNextUrl(
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
    final key = '${bookId}_${sourceId}_${CatalogParser.resolveUrl(
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
      final resolvedDetailUrl = CatalogParser.resolveUrl(
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
        contentUrl = RuleVariables.expand(ContentExtractor.buildContentUrl(
          source.contentUrl!,
          chapterUrl,
          chapterIndex,
          resolvedDetailUrl,
        ), effectiveVariables);
      } else if (chapterUrl.isNotEmpty) {
        if (chapterUrl.startsWith('http')) {
          contentUrl = chapterUrl;
        } else if (resolvedDetailUrl.isNotEmpty) {
          contentUrl = CatalogParser.resolveUrl(resolvedDetailUrl, chapterUrl);
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
        final part = await ContentExtractor.extractContentPage(
          source,
          pageHtml,
          pageUrl,
          effectiveVariables,
        );
        if (part.isNotEmpty) contentParts.add(part);
        final nextRule = source.nextContentUrl;
        if (nextRule == null || nextRule.trim().isEmpty) break;
        final nextUrl = await CatalogParser.extractNextUrl(
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
      content = ContentExtractor.applyContentReplaceRegex(source.contentReplaceRegex, content);

      // ruleContent.title：正文标题规则。先提取正文页标题，非空才覆盖
      // 章节标题（目录标题为空或与正文不一致时以此为准）。
      var effectiveTitle = chapterTitle;
      final contentTitleRule = source.contentTitleRule;
      if (contentTitleRule != null && contentTitleRule.trim().isNotEmpty) {
        final extractedTitle = await CatalogParser.extractFromPage(
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
      content = ContentExtractor.resolveImageUrls(content, contentUrl);
      content = ContentExtractor.removeRepeatedTitle(content, effectiveTitle);

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

  /// 兼容转发：正文图片 URL 解析已迁至 [ContentExtractor]。
  static String resolveImageUrls(String html, String baseUrl) =>
      ContentExtractor.resolveImageUrls(html, baseUrl);



  /// 条目字段提取：完整 JS 规则走 quickjs，模板 JS/CSS/JSONPath 走原路径。

  /// 解析单个目录页为章节列表。


  /// 执行 ruleToc.formatJs：脚本内 item 含 {title, url}，返回修改后的
  /// {title, url}；执行失败/无引擎/结果非对象时返回 null（按原值兜底）。

  /// ruleToc.isVolume 求值：CSS 规则用 rule_engine 对目录条目求值
  /// （非空为真）；JS 规则走 item 作用域脚本（同 formatJs 机制）。

  /// JS 求值结果真值判断（legado 布尔规则语义：非空且非 false/0/null）。



  /// 提取目录下一页 URL。

  /// 完整 JS 列表规则结果通常为 JSON 数组/对象；解析失败时按无结果处理。

  /// 解析 Legado ruleBookInfo：先执行 init 切换内容，再读取目录 URL。

  BookDetail _toBookDetail({
    required String bookId,
    required ParsedBookInfo info,
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

  /// 相对路径基于详情页/书源域名 resolve；非 http(s) 或无法解析时原样返回。

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