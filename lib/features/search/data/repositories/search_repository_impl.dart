import 'dart:convert';
import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/search_repository.dart';
import 'package:html/dom.dart' as dom;
import '../engines/js_rule_executor.dart';
import '../engines/js_template.dart';
import '../engines/rule_engine.dart';

class SearchRepositoryImpl implements SearchRepository {
  final DioClient _client;

  /// 登录 Cookie 会话缓存 TTL：命中缓存直接复用，跳过重复 login 请求
  static const Duration _cookieTtl = Duration(minutes: 30);

  /// 按 sourceId 缓存的登录 Cookie 会话
  final Map<String, _CookieSession> _cookieCache = {};

  SearchRepositoryImpl({DioClient? client})
      : _client = client ?? DioClient();

  @override
  Future<List<SearchResult>> searchWithSource(String keyword, BookSource source, {CancelToken? cancelToken}) async {
    if (!source.enabled || source.searchUrl == null || source.bookListRule == null) {
      return [];
    }

    try {
      // 解析 Legado 搜索地址：URL 或 `URL,{json参数}`（method/body/charset）
      final spec = _parseSearchUrl(source.searchUrl!);
      final searchPath = spec?.url ?? source.searchUrl!;
      // 相对路径基于书源域名拼接
      final searchUrl = _resolveUrl(source.bookSourceUrl, searchPath);

      final headers = <String, String>{...source.requestHeaders};
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
            }
          } catch (_) {
            // 登录失败时仍尝试直接搜索，避免单个书源拖垮聚合搜索
          }
        }
      }

      final String html;
      if (spec != null && spec.method == 'POST' && spec.body != null) {
        // POST 表单：body 里 {{key}} 用表单编码替换
        final body = spec.body!
            .replaceAll('{{key}}', Uri.encodeQueryComponent(keyword));
        html = await _client.postForm(
          searchUrl,
          headers: headers.isEmpty ? null : headers,
          body: body,
          sourceId: source.id,
          charset: spec.charset,
          cancelToken: cancelToken,
        );
      } else {
        // GET 模板：无论是否解析出 JSON 参数，{{key}} 都要替换
        final url =
            searchUrl.replaceAll('{{key}}', Uri.encodeComponent(keyword));
        html = await _client.getString(
          url,
          headers: headers.isEmpty ? null : headers,
          sourceId: source.id,
          cancelToken: cancelToken,
        );
      }

      final items = RuleEngine.extractElements(html, source.bookListRule);
      final results = <SearchResult>[];

      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item == null) continue;

        final name = await _extractField(item, source.bookNameRule, html);
        if (name == null || name.isEmpty) continue;

        final detailUrl = await _extractField(item, source.bookDetailUrlRule, html);
        results.add(SearchResult(
          bookId: _stableBookId(source.id, detailUrl, i),
          name: name,
          author: await _extractField(item, source.bookAuthorRule, html),
          coverUrl: await _extractField(item, source.coverUrlRule, html),
          detailUrl: detailUrl,
          sourceId: source.id,
          sourceName: source.name,
        ));
      }

      return results;
    } catch (e) {
      // 主动取消（换词时中断旧批次）不视为错误：返回空结果，
      // 避免上层把取消误报为搜索失败
      if (e is DioException && e.type == DioExceptionType.cancel) return [];
      return [];
    }
  }

  /// 提取条目字段：模板 JS 同步走 RuleEngine；完整 JS（含 ajax/正则等）
  /// 走 quickjs 异步执行器；CSS/JSONPath 走原路径。
  Future<String?> _extractField(dynamic item, String? rule, String pageHtml) async {
    if (rule == null || rule.isEmpty) return null;
    if (RuleEngine.isJsRule(rule)) {
      if (JsTemplateEngine.canHandle(rule)) {
        return RuleEngine.getElementText(item, rule);
      }
      if (item is dom.Element) {
        return JsRuleExecutor.execute(item.outerHtml, rule);
      }
      return null;
    }
    return RuleEngine.getElementText(item, rule);
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
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (base == null || base.isEmpty) return path;
    return Uri.parse(base).resolve(path).toString();
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
