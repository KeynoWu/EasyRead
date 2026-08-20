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
            return;
          }
          final html = JsRuleExecutor.fetcher != null
              ? await JsRuleExecutor.fetcher!(resolved).timeout(JsRuleExecutor.ajaxTimeout)
              : await client
                    .getString(resolved, charset: charset)
                    .timeout(JsRuleExecutor.ajaxTimeout);
          results[url] = html;
        } catch (_) {
          results[url] = '';
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
      ];
    } catch (_) {
      return [];
    }
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
  }) async {
    // post/head 与 ajax 一样限制总量：否则恶意规则可在 3s eval 内 push
    // 海量操作，后续以 4 并发串行消费导致总时长与请求量近似无界。
    if (ops.length > maxFetchUrls) {
      ops = ops.sublist(0, maxFetchUrls);
    }
    final results = <String, Map<String, dynamic>>{};
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
            return;
          }
          final headers = op.headers;
          final Map<String, List<String>> responseHeaders;
          if (op.kind == 'post') {
            responseHeaders = await client.postFormHeaders(
              resolved,
              headers: headers.isEmpty ? null : headers,
              body: op.body,
            );
          } else {
            responseHeaders = await client.getResponseHeaders(
              resolved,
              headers: headers.isEmpty ? null : headers,
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
            'body': '',
          };
        } catch (_) {
          results[op.key] = {
            'headers': <String, String>{},
            'cookies': '',
            'body': '',
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