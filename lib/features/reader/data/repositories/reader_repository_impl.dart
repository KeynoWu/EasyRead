import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show DioException;
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/data/cookie_jar_service.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';
import '../../../../features/search/data/engines/js_rule_executor.dart';
import '../../../../features/search/data/engines/rule_variables.dart';
import '../../../../features/search/data/engines/url_spec.dart';
import '../../../settings/domain/entities/chinese_conversion.dart';
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
/// 章节加载错误类别（自动换源判定依据，对齐 Legado 仅书源级失败
/// 才自动换源、瞬时网络错误不触发的精神）：
/// - sourceError：书源/规则层失败（书源不可用/无法定位/内容为空）
/// - networkError：瞬时网络异常（超时/断网等），自动换源不触发
enum ChapterErrorKind { sourceError, networkError }

class ChapterLoadException implements Exception {
  final String message;
  final ChapterErrorKind kind;

  const ChapterLoadException(
    this.message, {
    this.kind = ChapterErrorKind.sourceError,
  });

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
    Duration? contentRetryInterval,
    this.cacheByteBudget,
  })  : _client = client ?? DioClient(),
        _pipeline = pipeline ?? PurifyPipeline(),
        _sourceRepo = sourceRepo ?? _EmptySourceRepo(),
        _cookieJar = cookieJar ?? CookieJarService(),
        contentRetryInterval = contentRetryInterval ?? const Duration(seconds: 1);

  /// 正文页抓取重试间隔（§三-12，Legado CacheBook 失败重试 3 次；
  /// 测试可注入短间隔）。
  final Duration contentRetryInterval;

  /// 章节缓存总字节预算（§三-6；null 用默认 64MB，测试可注入小值）。
  final int? cacheByteBudget;

  /// 运行时注入净化规则（用户配置加载完成后调用）
  void setPipeline(PurifyPipeline pipeline) {
    _pipeline = pipeline;
  }

  Future<BookSource?> _getSource(String sourceId) async {
    return _sourceRepo.getById(sourceId);
  }

  /// 封面/正文图片字节获取（§三-3 防盗链，对齐 Legado
  /// OkHttpStreamFetcher：带书源 headers + cookie 请求图片）。
  /// 相对 URL 基于书源地址解析；[sourceId] 为空或书源缺失时直取。
  Future<Uint8List> fetchImageBytes(
    String url, {
    String? sourceId,
    Map<String, String>? headers,
  }) async {
    var target = url;
    Map<String, String> effective = {...?headers};
    if (sourceId != null && sourceId.isNotEmpty) {
      final source = await _getSource(sourceId);
      if (source != null) {
        if (target.isNotEmpty && !target.startsWith('http')) {
          target = CatalogParser.resolveUrl(source.bookSourceUrl, target);
        }
        effective = {...await _requestHeaders(source, sourceId), ...?headers};
      }
    }
    return _client.getBytes(target, headers: effective, sourceId: sourceId);
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
    String method = 'GET',
    String? body,
    int retry = 0,
  }) async {
    final html = await _client.requestString(
      url,
      method: method,
      body: body,
      headers: headers.isEmpty ? null : headers,
      sourceId: sourceId,
      concurrentRate: source.concurrentRate,
      charset: charset,
      retry: retry,
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
      cookieHeader: storedCookie,
    );
    // 登录失效检测（§三-7，与 search 仓库 _applyLoginCheck 同语义）：
    // error: 前缀（执行结果或规则原文）→ 专用登录失效错误；startBrowser
    // 校验且无 Cookie → 需网页登录。分类为 sourceError（书源层失败，
    // 自动换源可尝试其他源）。
    final trimmed = value?.trim() ?? '';
    final rawCheck = loginCheckJs.trim();
    final expiredReason = trimmed.startsWith('error:')
        ? trimmed.substring(6).trim()
        : rawCheck.startsWith('error:')
            ? rawCheck.substring(6).trim()
            : null;
    if (expiredReason != null) {
      throw ChapterLoadException(
        expiredReason.isEmpty ? '登录已失效，请重新登录书源' : '登录已失效：$expiredReason',
        kind: ChapterErrorKind.sourceError,
      );
    }
    final hasCookie =
        (storedCookie?.isNotEmpty ?? false) || (headers['Cookie']?.isNotEmpty ?? false);
    if (trimmed.isEmpty &&
        !hasCookie &&
        loginCheckJs.contains('startBrowser')) {
      throw const ChapterLoadException(
        '登录已失效，请在书源列表重新登录（该源校验需要网页登录）',
        kind: ChapterErrorKind.sourceError,
      );
    }
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

  /// tocUrl/contentUrl/nextTocUrl 统一取回（P1：URL,{json} 选项 + 全 JS URL
  /// 接入，对齐 Legado AnalyzeUrl）：全 JS URL 绑定 page/baseUrl 求值；
  /// `,{json}` 选项支持 method/headers/body/charset/retry/js。
  /// spec.headers 覆盖源级 headers（Legado putAll 顺序）；无选项时保持
  /// 原 headers 引用语义（Cookie 回写传播给调用方）。
  Future<String> _fetchRuleUrl(
    BookSource source,
    String sourceId,
    String rawUrl,
    Map<String, String> headers, {
    int? page,
  }) async {
    final spec = await UrlSpec.parse(
      rawUrl,
      evalJs: (js, result) => JsRuleExecutor.evalUrlJs(
        js,
        page: page,
        baseUrl: source.bookSourceUrl,
        result: result,
      ),
    );
    final merged =
        spec.headers.isEmpty ? headers : {...headers, ...spec.headers};
    return _getStringWithLoginCheck(
      source,
      sourceId,
      spec.url,
      merged,
      charset: spec.charset ?? source.responseCharset,
      method: spec.method,
      body: spec.body,
      retry: spec.retry,
    );
  }

  /// 正文页抓取重试（§三-12，对齐 Legado CacheBook 失败重试 3 次）：
  /// 仅重试瞬时网络异常（DioException），间隔 [contentRetryInterval]；
  /// 书源级失败（ChapterLoadException）立即抛出。
  static const int _contentRetryTimes = 3;

  Future<String> _fetchContentPageWithRetry(
    BookSource source,
    String sourceId,
    String rawUrl,
    Map<String, String> headers, {
    int? page,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _fetchRuleUrl(source, sourceId, rawUrl, headers, page: page);
      } on DioException {
        if (attempt > _contentRetryTimes) rethrow;
        await Future<void>.delayed(contentRetryInterval);
      }
    }
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
    // bookUrlPattern 生效（§三-10，Legado「链接为详情页」判定 BookList.kt:50）：
    // 详情页 URL 与 pattern 不匹配 → 非该源的真实详情页，直接报错——
    // 自动换源时无效候选被拒，正常加载给出明确错误而非错页解析。
    // pattern 为空/非法正则时 matchesBookUrlPattern 返回 true 放行。
    if (!matchesBookUrlPattern(source.bookUrlPattern, resolvedDetailUrl)) {
      throw const ChapterLoadException('详情页 URL 与书源 bookUrlPattern 不匹配');
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
      // 目录标题净化在返回时套用（缓存存原始标题，改净化规则即生效）
      return _purifyCatalogTitles(_cachedCatalog!, source, bookId);
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
          tocHtml = await _fetchRuleUrl(source, sourceId, tocUrl, headers);
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
        pageHtml = await _fetchRuleUrl(source, sourceId, nextUrl, headers);
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
      // 目录标题净化在返回时套用（缓存保留原始标题）
      return _purifyCatalogTitles(catalog, source, bookId);
    } on ChapterLoadException {
      rethrow;
    } catch (e) {
      // 目录加载失败（网络/解析）：抛错而非静默返空目录，
      // 避免上层误判"无章节"进而级联成无关的章节加载失败。
      throw const ChapterLoadException('目录加载失败');
    }
  }

  /// 目录标题净化（§三-10，Legado getDisplayTitle(titleReplaceRules)）：
  /// 标题作用域规则在目录返回时套用，缓存保留原始标题——改净化规则
  /// 下次取目录即生效（与正文净化双层时机同原则）。
  Future<ChapterCatalog> _purifyCatalogTitles(
    ChapterCatalog catalog,
    BookSource source,
    String bookId,
  ) async {
    if (catalog.chapters.isEmpty) return catalog;
    // 书名净化参数只允许使用当前书的详情（与 getChapter 同守卫）
    final effectiveBookName =
        _lastBookDetail != null && _lastBookDetail!.bookId == bookId
            ? _lastBookDetail!.name
            : null;
    final chapters = <ChapterItem>[];
    for (final chapter in catalog.chapters) {
      chapters.add(ChapterItem(
        title: await _pipeline.purifyTitle(
          chapter.title,
          bookName: effectiveBookName,
          sourceName: source.name,
          sourceUrl: source.bookSourceUrl,
        ),
        url: chapter.url,
        index: chapter.index,
        variables: chapter.variables,
        isVolume: chapter.isVolume,
      ));
    }
    return ChapterCatalog(
      bookId: catalog.bookId,
      chapters: chapters,
      fetchedAt: catalog.fetchedAt,
    );
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
    ChineseConversionMode chineseMode = ChineseConversionMode.original,
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
      // 用户净化规则在阅读时套用（缓存只存源规则后原文，
      // 改规则无需清缓存即生效）
      return _applyUserPurify(
        cached.toEntity(),
        source,
        bookId,
        chineseMode: chineseMode,
      );
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
      // 下一章 URL：nextContentUrl 翻页的跨章守卫用（Legado
      // BookContent.kt:47-52 nextUrl==nextChapterUrl 即停，防下章正文混入）
      var nextChapterUrl = '';
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
            if (chapterIndex + 1 < catalog.chapters.length) {
              nextChapterUrl = catalog.chapters[chapterIndex + 1].url;
              if (nextChapterUrl.isNotEmpty &&
                  !nextChapterUrl.startsWith('http') &&
                  resolvedDetailUrl.isNotEmpty) {
                nextChapterUrl = CatalogParser.resolveUrl(
                  resolvedDetailUrl,
                  nextChapterUrl,
                );
              }
            }
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
      // 正文页抓取带重试（§三-12）
      final html =
          await _fetchContentPageWithRetry(source, sourceId, contentUrl, headers);

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
          cookieHeader: headers['Cookie'],
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
        // 跨章守卫：下一页 URL == 下一章 URL 时必须停（含解析到同一
        // 绝对 URL 的相对/绝对差异），否则下一章正文混入当前章
        if (nextUrl.isEmpty ||
            (nextChapterUrl.isNotEmpty &&
                (nextUrl == nextChapterUrl ||
                    CatalogParser.resolveUrl(pageUrl, nextUrl) ==
                        nextChapterUrl)) ||
            !visitedPages.add(nextUrl)) {
          break;
        }
        pageUrl = nextUrl;
        // 翻页抓取同样带重试（§三-12）
        pageHtml = await _fetchContentPageWithRetry(
          source,
          sourceId,
          nextUrl,
          headers,
        );
      }
      var content = contentParts.join('\n');
      // 提取为空时不再整页 HTML 兜底：下面统一以 ChapterLoadException
      // 明确报错，由 UI 展示错误+重试，避免把整页 HTML 当正文
      // （"像 Web"体验的根源）。

      // ruleContent.replaceRegex：Legado 语义 = 作用于全文的完整规则
      // （## 链为主流 / @js: 规则 / 存量 ["pat","rep"] 与 || 兼容）
      content = await ContentExtractor.applyContentReplaceRegex(
        source.contentReplaceRegex,
        content,
        baseUrl: contentUrl,
        variables: effectiveVariables,
        jsLib: source.jsLib,
        charset: source.responseCharset,
        cookieHeader: headers['Cookie'],
      );

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
          jsLib: source.jsLib,
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
      // 双层净化时机（对齐 Legado BookContent/ContentProcessor 分层）：
      // 缓存层只存「源规则后原文」（图片 URL 解析 + 重复标题去除属源层），
      // 用户净化规则（含书名/源作用域）阅读时套用——改规则不清缓存即生效。
      content = ContentExtractor.resolveImageUrls(content, contentUrl);
      content = ContentExtractor.removeRepeatedTitle(content, effectiveTitle);

      if (content.trim().isEmpty) {
        throw const ChapterLoadException('章节内容为空或解析失败，请重试或更换书源');
      }

      final rawTitle = effectiveTitle.isEmpty ? '第${chapterIndex + 1}章' : effectiveTitle;
      final chapter = Chapter(
        id: cacheKey,
        bookId: bookId,
        title: rawTitle,
        content: content,
        index: chapterIndex,
        sourceId: sourceId,
        cachedAt: DateTime.now(),
      );

      await cacheBox.put(cacheKey, ChapterModel.fromEntity(chapter));
      await _trimCache(cacheBox);
      // 用户净化规则在阅读时套用（返回值仍为净化后内容，缓存保留原文）
      return _applyUserPurify(
        chapter,
        source,
        bookId,
        bookName: effectiveBookName,
        chineseMode: chineseMode,
      );
    } on ChapterLoadException {
      // 已含明确语义的错误（书源不可用/无法定位/内容为空）直接透传，
      // 不被兜底文案覆盖，便于用户定位问题。
      rethrow;
    } catch (_) {
      // 兜底 = 瞬时网络异常（超时/断网/SSL 等）：自动换源不触发，
      // 由用户手动重试判断是否恢复。
      throw const ChapterLoadException(
        '章节加载失败，请检查网络或书源规则',
        kind: ChapterErrorKind.networkError,
      );
    }
  }

  /// 用户净化规则阅读时套用（Legado ContentProcessor.getContent 时机）：
  /// 简繁转换先于净化规则（Legado getContent 顺序 chineseConvert → 替换
  /// 规则，繁体站配简体净化规则可命中）；正文走内容作用域规则，标题走
  /// 标题作用域规则；净化后为空且原文非空视为规则错误，报错而不展示
  /// 空章节（与旧「净化后判空」行为一致）。
  Future<Chapter> _applyUserPurify(
    Chapter chapter,
    BookSource? source,
    String bookId, {
    String? bookName,
    ChineseConversionMode chineseMode = ChineseConversionMode.original,
  }) async {
    final convertedContent = ChineseConversion.convert(
      chapter.content,
      chineseMode,
    );
    final content = await _pipeline.purifyAsync(
      convertedContent,
      bookName: bookName,
      sourceName: source?.name,
      sourceUrl: source?.bookSourceUrl,
    );
    if (content.trim().isEmpty && chapter.content.trim().isNotEmpty) {
      throw const ChapterLoadException('章节内容为空或解析失败，请重试或更换书源');
    }
    final title = await _pipeline.purifyTitle(
      ChineseConversion.convert(chapter.title, chineseMode),
      bookName: bookName,
      sourceName: source?.name,
      sourceUrl: source?.bookSourceUrl,
    );
    return Chapter(
      id: chapter.id,
      bookId: chapter.bookId,
      title: title,
      content: content,
      index: chapter.index,
      sourceId: chapter.sourceId,
      cachedAt: chapter.cachedAt,
    );
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

  /// 缓存上限控制：条目数 [maxEntries] + 总字节预算（§三-6；长章节下
  /// 500 条可能体积过大，双限并行，超限淘汰最旧条目。体积以 content
  /// 长度（UTF-16 码元数）近似计——预算为量级控制，非精确字节审计）。
  static const int maxEntries = 500;
  static const int _defaultCacheByteBudget = 64 * 1024 * 1024;

  Future<void> _trimCache(Box<ChapterModel> box) async {
    final budget = cacheByteBudget ?? _defaultCacheByteBudget;
    var totalUnits = 0;
    for (final entry in box.values) {
      totalUnits += entry.content.length;
    }
    if (box.length <= maxEntries && totalUnits <= budget) return;
    final entries = box.values.toList()
      ..sort((a, b) {
        final at = a.cachedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.cachedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return at.compareTo(bt);
      });
    // 从最旧开始淘汰，直到条目数与字节预算同时达标
    final victims = <String>[];
    var count = box.length;
    for (final entry in entries) {
      if (count <= maxEntries && totalUnits <= budget) break;
      victims.add(entry.key);
      count--;
      totalUnits -= entry.content.length;
    }
    await box.deleteAll(victims);
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