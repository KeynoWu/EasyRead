import 'dart:async';
import 'dart:convert';
import 'package:easy_quickjs/quickjs.dart';
import '../../../../core/network/dio_client.dart';
import 'js_rule_executor.dart';

/// JS 桥 ajax/post/head 安全网络实现。
/// 出站限制：仅允许与书源页同站（同 host 或子域）请求，封堵 Cookie 外带；
/// 请求走 DioClient（SSRF 校验/重定向安全/限频）或注入的 [JsRuleExecutor.fetcher]。
class JsNetwork {
  static const int maxConcurrentFetches = 4;

  /// 单次执行最多拉取的 URL 总数：超限直接丢弃多余 URL，
  /// 防止 java.ajax 无界推入导致 N/4×8s 的总时长失控与后台请求泄漏。
  static const int maxFetchUrls = 50;

  static Future<Map<String, String>> fetchAll(
    List<String> urls, {
    String baseUrl = '',
    String? charset,
    Map<String, String> baseHeaders = const {},
  }) async {
    if (urls.length > maxFetchUrls) {
      urls = urls.sublist(0, maxFetchUrls);
    }
    final results = <String, String>{};
    final client = JsRuleExecutor.networkClient ?? DioClient();
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= urls.length) return;
        final url = urls[index];
        try {
          final resolved = resolveUrl(baseUrl, url);
          if (!isSameSite(baseUrl, resolved)) {
            results[url] = '';
            continue;
          }
          final html = JsRuleExecutor.fetcher != null
              ? await JsRuleExecutor.fetcher!(resolved).timeout(JsRuleExecutor.ajaxTimeout)
              : await client
                    .getString(
                      resolved,
                      charset: charset,
                      headers: baseHeaders.isEmpty ? null : baseHeaders,
                    )
                    .timeout(JsRuleExecutor.ajaxTimeout);
          results[url] = html;
        } catch (e) {
          // 对齐 Legado：网络错误返回可识别错误串（AnalyzeRule.kt:783
          // stackTraceStr 语义），JS 侧可据此感知失败，而非拿到与
          // 空页面不可区分的 ''
          results[url] = 'Exception: $e';
        }
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < maxConcurrentFetches && i < urls.length; i++)
        worker(),
    ];
    await Future.wait(workers);
    return results;
  }
  static Future<List<NetworkOp>> readNetworkOps(JsEngine engine) async {
    try {
      final posts =
          jsonDecode(
                (await engine
                        .eval('JSON.stringify(__postOps)')
                        .timeout(JsRuleExecutor.evalTimeout))
                    .value,
              )
              as List;
      final heads =
          jsonDecode(
                (await engine
                        .eval('JSON.stringify(__headOps)')
                        .timeout(JsRuleExecutor.evalTimeout))
                    .value,
              )
              as List;
      // java.connect(url[, headerJson])：完整 StrResponse（Legado JsExtensions.kt:136）
      final connects =
          jsonDecode(
                (await engine
                        .eval('JSON.stringify(__connectOps || [])')
                        .timeout(JsRuleExecutor.evalTimeout))
                    .value,
              )
              as List;
      // java.get(url, headers) 两参形式 = 网络 GET（Legado JsExtensions.kt:359）
      final get2s =
          jsonDecode(
                (await engine
                        .eval('JSON.stringify(__get2Ops || [])')
                        .timeout(JsRuleExecutor.evalTimeout))
                    .value,
              )
              as List;
      return [
        for (final raw in posts)
          NetworkOp(
            kind: 'post',
            url: raw is List && raw.isNotEmpty ? raw[0].toString() : '',
            body: raw is List && raw.length > 1 ? raw[1].toString() : '',
            headers: stringMap(raw is List && raw.length > 2 ? raw[2] : null),
          ),
        for (final raw in heads)
          NetworkOp(
            kind: 'head',
            url: raw is List && raw.isNotEmpty ? raw[0].toString() : '',
            headers: stringMap(raw is List && raw.length > 1 ? raw[1] : null),
          ),
        for (final raw in get2s)
          NetworkOp(
            kind: 'get2',
            url: raw is List && raw.isNotEmpty ? raw[0].toString() : '',
            headers: _headersFromJson(
              raw is List && raw.length > 1 ? raw[1] : null,
            ),
          ),
        for (final raw in connects)
          NetworkOp(
            kind: 'connect',
            url: raw is List && raw.isNotEmpty ? raw[0].toString() : '',
            headers: _headersFromJson(
              raw is List && raw.length > 1 ? raw[1] : null,
            ),
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  /// get2 操作的 headers 参数为 JSON 串（JS 侧已 JSON.stringify 归一）
  static Map<String, String> _headersFromJson(dynamic value) {
    if (value is Map) return stringMap(value);
    if (value is String && value.trim().startsWith('{')) {
      try {
        return stringMap(jsonDecode(value));
      } catch (_) {
        return {};
      }
    }
    return {};
  }
  static Map<String, String> stringMap(dynamic value) {
    if (value is! Map) return {};
    return {
      for (final entry in value.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }
  static Future<Map<String, Map<String, dynamic>>> fetchNetworkResults(
    List<NetworkOp> ops, {
    String baseUrl = '',
    String? charset,
    Map<String, String> baseHeaders = const {},
  }) async {
    // post/head 与 ajax 一样限制总量：否则恶意规则可在 3s eval 内 push
    // 海量操作，后续以 4 并发串行消费导致总时长与请求量近似无界。
    if (ops.length > maxFetchUrls) {
      ops = ops.sublist(0, maxFetchUrls);
    }
    final results = <String, Map<String, dynamic>>{};
    final connectStatus = <String, int>{};
    final client = JsRuleExecutor.networkClient ?? DioClient();
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= ops.length) return;
        final op = ops[index];
        try {
          final resolved = resolveUrl(baseUrl, op.url);
          if (!isSameSite(baseUrl, resolved)) {
            results[op.key] = {
              'headers': <String, String>{},
              'cookies': '',
              'body': '',
            };
            continue;
          }
          // 缓存键只由规则自带头构成（与 JS 侧一致）；基础头（如登录
          // Cookie）仅在发请求时合并，且不覆盖规则自带同名头
          final headers = op.headers;
          final requestHeaders = headers.isEmpty && baseHeaders.isEmpty
              ? null
              : {...baseHeaders, ...headers};
          final Map<String, List<String>> responseHeaders;
          var body = '';
          if (op.kind == 'post') {
            // Legado java.post 返回完整 Response（body + headers），
            // 读 POST 响应体的源（API 型）依赖 body
            final (postBody, postHeaders) = await client.postFormFull(
              resolved,
              headers: requestHeaders,
              body: op.body,
              charset: charset,
            );
            body = postBody;
            responseHeaders = postHeaders;
          } else if (op.kind == 'connect') {
            // 与 ajax 一致：fetcher 测试桩优先（无响应头/状态 200）
            if (JsRuleExecutor.fetcher != null) {
              body = await JsRuleExecutor
                  .fetcher!(resolved)
                  .timeout(JsRuleExecutor.ajaxTimeout);
              responseHeaders = const {};
              connectStatus[op.key] = 200;
            } else {
              final (cBody, cHeaders, cStatus) = await client.getResponse(
                resolved,
                headers: requestHeaders,
                charset: charset,
              );
              body = cBody;
              responseHeaders = cHeaders;
              connectStatus[op.key] = cStatus;
            }
          } else if (op.kind == 'get2') {
            // 与 ajax 一致：优先注入的 fetcher 测试桩（headers 不透传），
            // 否则走 DioClient 带 headers 的 GET
            body = JsRuleExecutor.fetcher != null
                ? await JsRuleExecutor
                    .fetcher!(resolved)
                    .timeout(JsRuleExecutor.ajaxTimeout)
                : await client
                    .getString(
                      resolved,
                      headers: requestHeaders,
                      charset: charset,
                    )
                    .timeout(JsRuleExecutor.ajaxTimeout);
            responseHeaders = {};
          } else {
            responseHeaders = await client.getResponseHeaders(
              resolved,
              headers: requestHeaders,
            );
          }
          final flattened = <String, String>{};
          final setCookies = <String>[];
          for (final entry in responseHeaders.entries) {
            final key = entry.key.toLowerCase();
            flattened[key] = entry.value.join('; ');
            if (key == 'set-cookie') {
              setCookies.addAll(entry.value);
            }
          }
          results[op.key] = {
            'headers': flattened,
            'cookies': setCookies.map((v) => v.split(';').first).join('; '),
            'body': body,
            if (connectStatus.containsKey(op.key))
              'status': connectStatus[op.key],
          };
        } catch (e) {
          // 网络错误对齐 Legado 错误串语义（不静默 ''）
          results[op.key] = {
            'headers': <String, String>{},
            'cookies': '',
            'body': 'Exception: $e',
          };
        }
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < maxConcurrentFetches && i < ops.length; i++)
        worker(),
    ];
    await Future.wait(workers);
    return results;
  }
  static String resolveUrl(String baseUrl, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (baseUrl.isEmpty) return url;
    return Uri.parse(baseUrl).resolve(url).toString();
  }
  /// 网络桥出站限制：只允许与书源页同站（同 host 或子域）的请求。
  /// 封堵恶意书源把 java.getCookie 读出的会话凭据经 java.ajax/post/head
  /// 外带到任意第三方域；同时保留 api.example.com → example.com 这类
  /// 书源常用的跨子域调用。baseUrl 为空（测试/无页面上下文）时不限制。
  static bool isSameSite(String baseUrl, String targetUrl) {
    if (baseUrl.isEmpty || targetUrl.isEmpty) return true;
    try {
      final base = Uri.parse(baseUrl);
      final target = Uri.parse(targetUrl);
      if (base.scheme.isEmpty || target.scheme.isEmpty) return false;
      if (base.scheme != target.scheme || base.port != target.port) {
        return false;
      }
      final baseHost = base.host.toLowerCase();
      final targetHost = target.host.toLowerCase();
      if (baseHost == targetHost) return true;
      return targetHost.endsWith('.$baseHost') ||
          baseHost.endsWith('.$targetHost');
    } catch (_) {
      return false;
    }
  }
}

class NetworkOp {
  final String kind;
  final String url;
  final String body;
  final Map<String, String> headers;

  const NetworkOp({
    required this.kind,
    required this.url,
    this.body = '',
    this.headers = const {},
  });

  String get key => '$url|$body|${jsonEncode(headers)}';
}