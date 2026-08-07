import 'dart:convert';
import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/data/cookie_jar_service.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../../../features/book_source/domain/entities/book_source_debug_result.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/search_repository.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import '../engines/js_rule_executor.dart';
import '../engines/js_template.dart';
import '../engines/rule_engine.dart';
import '../engines/rule_template.dart';
import '../engines/rule_variables.dart';

class SearchRepositoryImpl implements SearchRepository {
  final DioClient _client;
  final CookieJarService _cookieJar;

  /// 登录 Cookie 会话缓存 TTL：命中缓存直接复用，跳过重复 login 请求
  static const Duration _cookieTtl = Duration(minutes: 30);

  /// 按 sourceId 缓存的登录 Cookie 会话
  final Map<String, _CookieSession> _cookieCache = {};

  SearchRepositoryImpl({DioClient? client, CookieJarService? cookieJar})
      : _client = client ?? DioClient(),
        _cookieJar = cookieJar ?? CookieJarService();

  @override
  Future<List<SearchResult>> searchWithSource(
    String keyword,
    BookSource source, {
    int? page,
    CancelToken? cancelToken,
    bool throwOnError = false,
  }) async {
    if (!source.enabled || source.searchUrl == null || source.bookListRule == null) {
      return [];
    }

    try {
      // 解析 Legado 搜索地址：URL 或 `URL,{json参数}`（method/body/charset）
      final spec = _parseSearchUrl(source.searchUrl!);
      final charset = spec?.charset ?? source.responseCharset;
      final rawSearchPath = spec?.url ?? source.searchUrl!;
      final searchPath =
          (await JsRuleExecutor.evalTemplate(
            rawSearchPath,
            page: page,
            baseUrl: source.bookSourceUrl,
            charset: charset,
          )) ??
          rawSearchPath;
      // 相对路径基于书源域名拼接
      final searchUrl = _resolveUrl(
        source.bookSourceUrl,
        RuleTemplate.interpolate(
          searchPath,
          values: {'key': keyword},
          page: page,
          encodeValues: true,
        ),
      );

      final headers = <String, String>{...source.requestHeaders};
      if (source.enabledCookieJar) {
        final storedCookie = await _cookieJar.get(source.id);
        if (storedCookie != null && storedCookie.isNotEmpty) {
          headers.putIfAbsent('Cookie', () => storedCookie);
        }
      }
      if (source.loginUrl != null &&
          source.loginUrl!.isNotEmpty &&
          !headers.containsKey('Cookie')) {
        final cached = _cookieCache[source.id];
        if (cached != null && cached.isValid) {
          // 会话未过期：复用缓存 Cookie，跳过重复 login 请求
          headers['Cookie'] = cached.cookie;
        } else {
          try {
            // loginUrl 支持 GET 或 Legado POST 格式（URL,{json}）
            final loginSpec = _parseSearchUrl(source.loginUrl!);
            final loginPath = loginSpec?.url ?? source.loginUrl!;
            final loginUrl = _resolveUrl(source.bookSourceUrl, loginPath);
            final Map<String, List<String>> loginHeaders;
            if (loginSpec != null &&
                loginSpec.method == 'POST' &&
                loginSpec.body != null) {
              loginHeaders = await _client.postFormHeaders(
                loginUrl,
                headers: headers.isEmpty ? null : headers,
                body: loginSpec.body,
                sourceId: source.id,
                cancelToken: cancelToken,
              );
            } else {
              loginHeaders = await _client.getResponseHeaders(
                loginUrl,
                headers: headers.isEmpty ? null : headers,
                sourceId: source.id,
                cancelToken: cancelToken,
              );
            }
            final setCookies = loginHeaders['set-cookie'] ?? const [];
            if (setCookies.isNotEmpty) {
              final cookie = setCookies
                  .map((value) => value.split(';').first)
                  .join('; ');
              headers['Cookie'] = cookie;
              _cookieCache[source.id] = _CookieSession(cookie);
              await _cookieJar.set(source.id, cookie);
            }
          } catch (_) {
            // 登录失败时仍尝试直接搜索，避免单个书源拖垮聚合搜索
          }
        }
      }

      final String html;
      if (spec != null && spec.method == 'POST' && spec.body != null) {
        // POST 表单：body 里 {{key}} 用表单编码替换
        final rawBody = spec.body!;
        final bodyTemplate =
            (await JsRuleExecutor.evalTemplate(
              rawBody,
              page: page,
              baseUrl: searchUrl,
              charset: charset,
            )) ??
            rawBody;
        final body = RuleTemplate.interpolate(
          bodyTemplate,
          values: {'key': keyword},
          page: page,
          encodeValues: true,
        );
        html = await _client.postForm(
          searchUrl,
          headers: headers.isEmpty ? null : headers,
          body: body,
          sourceId: source.id,
          charset: charset,
          cancelToken: cancelToken,
        );
      } else {
        html = await _client.getString(
          searchUrl,
          headers: headers.isEmpty ? null : headers,
          sourceId: source.id,
          charset: charset,
          cancelToken: cancelToken,
        );
      }

      var responseHtml = html;
      final loginCheckJs = source.loginCheckJs;
      if (loginCheckJs != null && loginCheckJs.isNotEmpty) {
        final cookieStore = <String, String>{};
        final storedCookie = headers['Cookie'];
        if (storedCookie != null && storedCookie.isNotEmpty) {
          cookieStore[source.id] = storedCookie;
          cookieStore[source.bookSourceUrl ?? ''] = storedCookie;
          cookieStore[searchUrl] = storedCookie;
        }
        final loginValue = await JsRuleExecutor.execute(
          responseHtml,
          loginCheckJs,
          baseUrl: searchUrl,
          charset: charset,
          cookies: cookieStore,
        );
        final updatedCookie = cookieStore[source.id] ??
            cookieStore[source.bookSourceUrl ?? ''] ??
            cookieStore[searchUrl] ??
            '';
        if (updatedCookie.isNotEmpty) {
          headers['Cookie'] = updatedCookie;
          _cookieCache[source.id] = _CookieSession(updatedCookie);
          await _cookieJar.set(source.id, updatedCookie);
        } else if (cookieStore.containsKey(source.id) ||
            cookieStore.containsKey(source.bookSourceUrl ?? '') ||
            cookieStore.containsKey(searchUrl)) {
          headers.remove('Cookie');
          _cookieCache.remove(source.id);
          await _cookieJar.remove(source.id);
        }
        if (loginValue != null && loginValue.isNotEmpty) {
          responseHtml = loginValue;
        }
      }

      final List<dynamic> items;
      final pageVariables = <String, String>{};
      if (RuleEngine.isJsRule(source.bookListRule!)) {
        final value = await JsRuleExecutor.execute(
          responseHtml,
          source.bookListRule!,
          baseUrl: searchUrl,
          charset: charset,
          variables: pageVariables,
        );
        items = _decodeJsListItems(value);
      } else {
        items = RuleEngine.extractElements(responseHtml, source.bookListRule);
      }
      final results = <SearchResult>[];

      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item == null) continue;
        final itemVariables = {...pageVariables};
        _collectSearchVariables(source, item, itemVariables);

        final name = await _extractField(
          item,
          source.bookNameRule,
          responseHtml,
          baseUrl: searchUrl,
          charset: charset,
          variables: itemVariables,
        );
        if (name == null || name.isEmpty) continue;

        final rawDetailUrl = await _extractField(
          item,
          source.bookDetailUrlRule,
          responseHtml,
          baseUrl: searchUrl,
          charset: charset,
          variables: itemVariables,
        );
        final detailUrl = rawDetailUrl == null
            ? null
            : _resolveUrl(searchUrl, rawDetailUrl);
        final rawCoverUrl = await _extractField(
          item,
          source.coverUrlRule,
          responseHtml,
          baseUrl: searchUrl,
          charset: charset,
          variables: itemVariables,
        );
        final intro = await _extractField(
          item,
          source.introRule,
          responseHtml,
          baseUrl: searchUrl,
          charset: charset,
          variables: itemVariables,
        );
        final kind = await _extractField(
          item,
          source.kindRule,
          responseHtml,
          baseUrl: searchUrl,
          charset: charset,
          variables: itemVariables,
        );
        final lastChapter = await _extractField(
          item,
          source.lastChapterRule,
          responseHtml,
          baseUrl: searchUrl,
          charset: charset,
          variables: itemVariables,
        );
        final wordCount = await _extractField(
          item,
          source.wordCountRule,
          responseHtml,
          baseUrl: searchUrl,
          charset: charset,
          variables: itemVariables,
        );
        results.add(SearchResult(
          bookId: _stableBookId(source.id, rawDetailUrl, i),
          name: name,
          author: await _extractField(
            item,
            source.bookAuthorRule,
            responseHtml,
            baseUrl: searchUrl,
            charset: charset,
            variables: itemVariables,
          ),
          coverUrl: rawCoverUrl == null
              ? null
              : _resolveUrl(searchUrl, rawCoverUrl),
          detailUrl: detailUrl,
          intro: intro,
          kind: kind,
          lastChapter: lastChapter,
          wordCount: wordCount,
          sourceId: source.id,
          sourceName: source.name,
          variables: Map.unmodifiable(itemVariables),
        ));
      }

      return results;
    } catch (e) {
      // 主动取消（换词时中断旧批次）不视为错误：返回空结果，
      // 避免上层把取消误报为搜索失败
      if (e is DioException && e.type == DioExceptionType.cancel) return [];
      // throwOnError：流式聚合/书源检测需要区分"单源失败"与"真无结果"，
      // 透传异常让上层统一计数失败并给出可重试入口
      if (throwOnError) rethrow;
      return [];
    }
  }

  @override
  Future<List<SearchResult>> exploreWithSource(
    BookSource source,
    String url, {
    int? page,
    CancelToken? cancelToken,
    bool throwOnError = false,
  }) async {
    if (!source.enabled || url.trim().isEmpty) return [];
    try {
      final spec = _parseSearchUrl(url);
      final charset = spec?.charset ?? source.responseCharset;
      final rawPath = spec?.url ?? url;
      final path =
          (await JsRuleExecutor.evalTemplate(
            rawPath,
            page: page,
            baseUrl: source.bookSourceUrl,
            charset: charset,
          )) ??
          rawPath;
      final requestUrl = RuleTemplate.interpolate(
        path,
        page: page,
      );
      final resolvedUrl = _resolveUrl(source.bookSourceUrl, requestUrl);
      final headers = <String, String>{...source.requestHeaders};
      if (source.enabledCookieJar) {
        final storedCookie = await _cookieJar.get(source.id);
        if (storedCookie != null && storedCookie.isNotEmpty) {
          headers.putIfAbsent('Cookie', () => storedCookie);
        }
      }
      await _ensureLoginHeaders(source, headers, resolvedUrl, cancelToken);
      final rawBody = spec?.body;
      final bodyTemplate =
          rawBody == null
              ? null
              : (await JsRuleExecutor.evalTemplate(
                  rawBody,
                  page: page,
                  baseUrl: resolvedUrl,
                  charset: charset,
                )) ??
                  rawBody;
      final html = spec != null && spec.method == 'POST' && bodyTemplate != null
          ? await _client.postForm(
              resolvedUrl,
              headers: headers.isEmpty ? null : headers,
              body: RuleTemplate.interpolate(bodyTemplate, page: page),
              sourceId: source.id,
              charset: charset,
              cancelToken: cancelToken,
            )
          : await _client.getString(
              resolvedUrl,
              headers: headers.isEmpty ? null : headers,
              sourceId: source.id,
              charset: charset,
              cancelToken: cancelToken,
            );
      final responseHtml = await _applyLoginCheck(
        source,
        html,
        resolvedUrl,
        charset,
        headers,
      );

      final listRule = source.exploreBookListRule ?? source.bookListRule;
      if (listRule == null) return [];
      final List<dynamic> items;
      final pageVariables = <String, String>{};
      if (RuleEngine.isJsRule(listRule)) {
        final value = await JsRuleExecutor.execute(
          responseHtml,
          listRule,
          baseUrl: resolvedUrl,
          charset: charset,
          variables: pageVariables,
        );
        items = _decodeJsListItems(value);
      } else {
        items = RuleEngine.extractElements(responseHtml, listRule);
      }

      final results = <SearchResult>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item == null) continue;
        final itemVariables = {...pageVariables};
        _collectSearchVariables(source, item, itemVariables);
        final name = await _extractField(
          item,
          source.exploreNameRule ?? source.bookNameRule,
          responseHtml,
          baseUrl: resolvedUrl,
          charset: charset,
          variables: itemVariables,
        );
        if (name == null || name.isEmpty) continue;
        final rawDetailUrl = await _extractField(
          item,
          source.exploreBookUrlRule ?? source.bookDetailUrlRule,
          responseHtml,
          baseUrl: resolvedUrl,
          charset: charset,
          variables: itemVariables,
        );
        final detailUrl = rawDetailUrl == null
            ? null
            : _resolveUrl(resolvedUrl, rawDetailUrl);
        final rawCoverUrl = await _extractField(
          item,
          source.exploreCoverUrlRule ?? source.coverUrlRule,
          responseHtml,
          baseUrl: resolvedUrl,
          charset: charset,
          variables: itemVariables,
        );
        results.add(SearchResult(
          bookId: _stableBookId(source.id, rawDetailUrl, i),
          name: name,
          author: await _extractField(
            item,
            source.exploreAuthorRule ?? source.bookAuthorRule,
            responseHtml,
            baseUrl: resolvedUrl,
            charset: charset,
            variables: itemVariables,
          ),
          coverUrl: rawCoverUrl == null
              ? null
              : _resolveUrl(resolvedUrl, rawCoverUrl),
          detailUrl: detailUrl,
          intro: await _extractField(
            item,
            source.exploreIntroRule ?? source.introRule,
            responseHtml,
            baseUrl: resolvedUrl,
            charset: charset,
            variables: itemVariables,
          ),
          kind: await _extractField(
            item,
            source.exploreKindRule ?? source.kindRule,
            responseHtml,
            baseUrl: resolvedUrl,
            charset: charset,
            variables: itemVariables,
          ),
          lastChapter: await _extractField(
            item,
            source.exploreLastChapterRule ?? source.lastChapterRule,
            responseHtml,
            baseUrl: resolvedUrl,
            charset: charset,
            variables: itemVariables,
          ),
          wordCount: await _extractField(
            item,
            source.exploreWordCountRule ?? source.wordCountRule,
            responseHtml,
            baseUrl: resolvedUrl,
            charset: charset,
            variables: itemVariables,
          ),
          sourceId: source.id,
          sourceName: source.name,
          variables: Map.unmodifiable(itemVariables),
        ));
      }
      return results;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return [];
      if (throwOnError) rethrow;
      return [];
    }
  }

  /// 调试搜索：返回原始响应片段与规则解析出的示例结果。
  Future<BookSourceDebugResult> debugSearch(
    String keyword,
    BookSource source,
  ) async {
    if (source.searchUrl == null || source.bookListRule == null) {
      return const BookSourceDebugResult(error: '书源缺少搜索 URL 或书籍列表规则');
    }
    try {
      final spec = _parseSearchUrl(source.searchUrl!);
      final path = spec?.url ?? source.searchUrl!;
      final searchUrl = _resolveUrl(
        source.bookSourceUrl,
        RuleTemplate.interpolate(
          path,
          values: {'key': keyword},
          encodeValues: true,
        ),
      );
      final headers = <String, String>{...source.requestHeaders};
      final charset = spec?.charset ?? source.responseCharset;
      if (source.enabledCookieJar) {
        final cookie = await _cookieJar.get(source.id);
        if (cookie != null && cookie.isNotEmpty) {
          headers.putIfAbsent('Cookie', () => cookie);
        }
      }
      final String html;
      if (spec != null && spec.method == 'POST' && spec.body != null) {
        html = await _client.postForm(
          searchUrl,
          headers: headers.isEmpty ? null : headers,
          body: spec.body!.replaceAll('{{key}}', Uri.encodeQueryComponent(keyword)),
          sourceId: source.id,
          charset: charset,
        );
      } else {
        html = await _client.getString(
          searchUrl,
          headers: headers.isEmpty ? null : headers,
          sourceId: source.id,
          charset: charset,
        );
      }
      final results = await _parseDebugResults(
        source,
        html,
        searchUrl,
        charset,
      );
      return BookSourceDebugResult(
        rawHtml: html.length > 8000 ? html.substring(0, 8000) : html,
        results: results.take(5).toList(),
      );
    } catch (e) {
      return BookSourceDebugResult(error: e.toString());
    }
  }

  Future<List<SearchResult>> _parseDebugResults(
    BookSource source,
    String html,
    String baseUrl,
    String? charset,
  ) async {
    final listRule = source.bookListRule;
    if (listRule == null) return [];
    final List<dynamic> items;
    if (RuleEngine.isJsRule(listRule)) {
      final value = await JsRuleExecutor.execute(
        html,
        listRule,
        baseUrl: baseUrl,
        charset: charset,
      );
      items = _decodeJsListItems(value);
    } else {
      items = RuleEngine.extractElements(html, listRule);
    }
    final results = <SearchResult>[];
    for (var i = 0; i < items.length && results.length < 5; i++) {
      final item = items[i];
      if (item == null) continue;
      final variables = <String, String>{};
      _collectSearchVariables(source, item, variables);
      final name = await _extractField(
        item,
        source.bookNameRule,
        html,
        baseUrl: baseUrl,
        charset: charset,
        variables: variables,
      );
      if (name == null || name.isEmpty) continue;
      final rawDetailUrl = await _extractField(
        item,
        source.bookDetailUrlRule,
        html,
        baseUrl: baseUrl,
        charset: charset,
        variables: variables,
      );
      results.add(SearchResult(
        bookId: _stableBookId(source.id, rawDetailUrl, i),
        name: name,
        author: await _extractField(
          item,
          source.bookAuthorRule,
          html,
          baseUrl: baseUrl,
          charset: charset,
          variables: variables,
        ),
        detailUrl: rawDetailUrl == null
            ? null
            : _resolveUrl(baseUrl, rawDetailUrl),
        sourceId: source.id,
        sourceName: source.name,
        variables: Map.unmodifiable(variables),
      ));
    }
    return results;
  }

  /// 提取条目字段：模板 JS 同步走 RuleEngine；完整 JS（含 ajax/正则等）
  /// 走 quickjs 异步执行器；CSS/JSONPath 走原路径。
  Future<String?> _extractField(
    dynamic item,
    String? rule,
    String pageHtml, {
    String? baseUrl,
    String? charset,
    Map<String, String>? variables,
  }) async {
    if (rule == null || rule.isEmpty) return null;
    var normalized = rule;
    final hadGet = normalized.contains('@get:{');
    if (variables != null) {
      normalized = RuleVariables.expand(normalized, variables);
      if (normalized.contains('@put:')) {
        normalized =
            RuleVariables.collectAndStrip(normalized, item, variables);
      }
    }
    rule = normalized;
    if (item is Map && hadGet && !rule.contains('{{')) {
      // @get 展开后的纯 URL/字符串规则：Map 条目下直接作为结果，
      // 避免被误当作 JSONPath 查询。
      return rule;
    }
    if (item is Map && rule.contains('{{')) {
      final json = Map<String, dynamic>.from(item);
      var template = rule;
      if (template.contains('{{java.')) {
        template = (await JsRuleExecutor.evalTemplate(
                  template,
                  json: json,
                  html: pageHtml,
                  baseUrl: baseUrl ?? '',
                  charset: charset,
                )) ??
                template;
      }
      return RuleTemplate.interpolate(
        template,
        json: json,
        html: pageHtml,
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
        baseUrl: baseUrl ?? '',
        charset: charset,
      );
    }
    return RuleEngine.getElementText(item, rule);
  }

  /// 预收集条目字段中的 `@put:` 变量，保证 URL 字段可以引用后续字段的变量。
  void _collectSearchVariables(
    BookSource source,
    dynamic item,
    Map<String, String> variables,
  ) {
    final rules = [
      source.bookDetailUrlRule,
      source.coverUrlRule,
      source.introRule,
      source.kindRule,
      source.lastChapterRule,
      source.wordCountRule,
      source.bookAuthorRule,
      source.exploreNameRule,
      source.exploreBookUrlRule,
      source.exploreCoverUrlRule,
      source.exploreIntroRule,
      source.exploreKindRule,
      source.exploreLastChapterRule,
      source.exploreWordCountRule,
    ];
    for (final rule in rules) {
      if (rule != null && rule.contains('@put:')) {
        RuleVariables.collectAndStrip(
          RuleVariables.expand(rule, variables),
          item,
          variables,
        );
      }
    }
  }

  /// 完整 JS 列表规则结果通常为 JSON 数组/对象；解析失败时按无结果处理。
  static List<dynamic> _decodeJsListItems(String? value) {
    if (value == null || value.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) return decoded;
      return [decoded];
    } catch (_) {
      // 非 JSON 时按 HTML 片段处理：至少能覆盖 JS 规则直接返回单本书 HTML 的场景。
      final doc = parser.parse(value);
      final body = doc.body;
      return body == null ? [] : [body];
    }
  }

  /// 基于详情 URL 生成稳定书 ID：同一本书在不同搜索中保持同一 ID，
  /// 避免列表索引变化导致缓存与阅读进度错位。
  static String _stableBookId(String sourceId, String? detailUrl, int index) {
    if (detailUrl != null && detailUrl.isNotEmpty) {
      return '${sourceId}_${base64Url.encode(utf8.encode(detailUrl))}';
    }
    return '${sourceId}_$index';
  }

  /// 解析 Legado 搜索地址：`URL` 或 `URL,{json参数}`。
  /// 参数：method（GET/POST）、body（POST 表单体）、charset（响应编码）。
  static _SearchSpec? _parseSearchUrl(String raw) {
    final comma = raw.indexOf(',{');
    if (comma <= 0 || comma >= raw.length - 2) return null;
    final url = raw.substring(0, comma).trim();
    if (url.isEmpty) return null;
    final params = _decodeParams(raw.substring(comma + 1));
    if (params == null) return null;
    return _SearchSpec(
      url: url,
      method: (params['method']?.toString() ?? 'GET').toUpperCase(),
      body: params['body']?.toString(),
      charset: params['charset']?.toString(),
    );
  }

  /// 解析参数 JSON：先按标准双引号解析；失败再尝试 Legado 单引号格式
  /// （盲替换单引号为双引号，body 值内含单引号时按失败处理退化 GET）
  static Map<String, dynamic>? _decodeParams(String jsonStr) {
    try {
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      // 单引号 JSON（Legado 惯例）转双引号后重试
      try {
        return jsonDecode(jsonStr.replaceAll("'", '"')) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
  }

  /// 相对路径基于书源域名拼接（如 /modules/article/search.php → https://host/modules/...）
  static String _resolveUrl(String? base, String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (base == null || base.isEmpty) return path;
    return Uri.parse(base).resolve(path).toString();
  }

  Future<void> _ensureLoginHeaders(
    BookSource source,
    Map<String, String> headers,
    String baseUrl,
    CancelToken? cancelToken,
  ) async {
    if (source.loginUrl == null ||
        source.loginUrl!.isEmpty ||
        headers.containsKey('Cookie')) {
      return;
    }
    final cached = _cookieCache[source.id];
    if (cached != null && cached.isValid) {
      headers['Cookie'] = cached.cookie;
      return;
    }
    try {
      final loginSpec = _parseSearchUrl(source.loginUrl!);
      final loginPath = loginSpec?.url ?? source.loginUrl!;
      final loginUrl = _resolveUrl(source.bookSourceUrl, loginPath);
      final Map<String, List<String>> loginHeaders;
      if (loginSpec != null &&
          loginSpec.method == 'POST' &&
          loginSpec.body != null) {
        loginHeaders = await _client.postFormHeaders(
          loginUrl,
          headers: headers.isEmpty ? null : headers,
          body: loginSpec.body,
          sourceId: source.id,
          cancelToken: cancelToken,
        );
      } else {
        loginHeaders = await _client.getResponseHeaders(
          loginUrl,
          headers: headers.isEmpty ? null : headers,
          sourceId: source.id,
          cancelToken: cancelToken,
        );
      }
      final setCookies = loginHeaders['set-cookie'] ?? const [];
      if (setCookies.isNotEmpty) {
        final cookie =
            setCookies.map((value) => value.split(';').first).join('; ');
        headers['Cookie'] = cookie;
        _cookieCache[source.id] = _CookieSession(cookie);
        await _cookieJar.set(source.id, cookie);
      }
    } catch (_) {
      // 登录失败时仍尝试直接请求
    }
  }

  Future<String> _applyLoginCheck(
    BookSource source,
    String html,
    String url,
    String? charset,
    Map<String, String> headers,
  ) async {
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
      _cookieCache[source.id] = _CookieSession(updatedCookie);
      await _cookieJar.set(source.id, updatedCookie);
    } else if (cookieStore.containsKey(source.id) ||
        cookieStore.containsKey(source.bookSourceUrl ?? '') ||
        cookieStore.containsKey(url)) {
      headers.remove('Cookie');
      _cookieCache.remove(source.id);
      await _cookieJar.remove(source.id);
    }
    return value != null && value.isNotEmpty ? value : html;
  }
}

/// 解析后的搜索请求规格
class _SearchSpec {
  final String url;
  final String method;
  final String? body;
  final String? charset;

  const _SearchSpec({
    required this.url,
    required this.method,
    this.body,
    this.charset,
  });
}

/// 登录 Cookie 会话缓存条目：记录抓取时间，TTL 过期后重新登录
class _CookieSession {
  final String cookie;
  final DateTime fetchedAt;

  _CookieSession(this.cookie) : fetchedAt = DateTime.now();

  bool get isValid => DateTime.now().difference(fetchedAt) < SearchRepositoryImpl._cookieTtl;
}
