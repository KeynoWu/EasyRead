import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'interceptors/rate_limit_interceptor.dart';
import 'interceptors/retry_interceptor.dart';
import 'interceptors/ua_interceptor.dart';

/// 全局 Dio 客户端 — 单例，所有网络请求通过此实例
class DioClient {
  static DioClient? _instance;
  final Dio _dio;

  DioClient._() : _dio = _buildDio();

  DioClient._withDio(Dio dio) : _dio = dio;

  @visibleForTesting
  DioClient.forTesting(Dio dio) : this._withDio(dio);

  static Dio _buildDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      followRedirects: false,
      validateStatus: (status) => status != null && status < 400,
      headers: {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    ));
    dio.interceptors.addAll([
      UaInterceptor(),
      RateLimitInterceptor(),
      RetryInterceptor(dio),
    ]);
    return dio;
  }

  factory DioClient() {
    _instance ??= DioClient._();
    return _instance!;
  }

  Dio get dio => _dio;

  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return _decodeBody(response.data, charset);
  }

  /// 请求并返回响应头，用于书源登录后捕获 Set-Cookie。
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
      cancelToken: cancelToken,
    );
    return response.headers.map;
  }

  /// 带下载进度回调的请求（大文件场景使用）
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final response = await _send(
      'GET',
      url,
      headers: headers,
      sourceId: sourceId,
      extra: extra,
      responseType: ResponseType.bytes,
      // 大文件下载的空闲判定由 ImportBookSource 控制，
      // 这里用 Duration.zero 禁用 Dio 固定 receiveTimeout，避免其先于上层超时生效。
      receiveTimeout: Duration.zero,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    return _decodeBody(response.data, charset);
  }

  /// POST 表单请求（Legado 书源搜索等场景）。
  /// [charset] 指定响应编码（gbk 等），默认 UTF-8。
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    final response = await _send(
      'POST',
      url,
      headers: {
        ...?headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: body,
      sourceId: sourceId,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return _decodeBody(response.data, charset);
  }

  /// POST 表单请求并返回响应头（书源登录等场景，部分接口需 POST 才能 Set-Cookie）
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    final response = await _send(
      'POST',
      url,
      headers: {
        ...?headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: body,
      sourceId: sourceId,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return response.headers.map;
  }

  /// 按 charset 解码响应字节
  static String _decodeBody(dynamic data, String? charset) {
    // 仅接受字节列表；异常类型不产出噪音文本
    if (data is! List<int>) return '';
    final lower = charset?.toLowerCase();
    if (lower == 'gbk' || lower == 'gb2312' || lower == 'gb18030') {
      try {
        return gbk.decode(data);
      } catch (_) {
        // GBK 解码失败回退 UTF-8
      }
    }
    return utf8.decode(data, allowMalformed: true);
  }

  Future<Response<dynamic>> _get(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    Map<String, dynamic>? extra,
    ResponseType? responseType,
    Duration? receiveTimeout,
    void Function(int received, int total)? onReceiveProgress,
    CancelToken? cancelToken,
  }) {
    return _send(
      'GET',
      url,
      headers: headers,
      sourceId: sourceId,
      extra: extra,
      responseType: responseType,
      receiveTimeout: receiveTimeout,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  /// 通用请求：重定向安全处理（SSRF 每跳校验 / 禁 HTTPS 降级 / 跨域清敏感头 / 上限 5 跳）
  Future<Response<dynamic>> _send(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? sourceId,
    Map<String, dynamic>? extra,
    ResponseType? responseType,
    Duration? receiveTimeout,
    void Function(int received, int total)? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    var current = url;
    var activeHeaders = headers;
    var currentUri = Uri.parse(current);
    for (var i = 0; i < 5; i++) {
      _assertSafeUrl(current);
      final options = Options(
        headers: activeHeaders,
        extra: {'source_id': sourceId, ...?extra},
        responseType: responseType ?? ResponseType.json,
        receiveTimeout: receiveTimeout,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      );
      final response = method == 'POST'
          ? await _dio.post<dynamic>(
              current,
              data: data,
              options: options,
              onReceiveProgress: onReceiveProgress,
              cancelToken: cancelToken,
            )
          : await _dio.get<dynamic>(
              current,
              options: options,
              onReceiveProgress: onReceiveProgress,
              cancelToken: cancelToken,
            );
      final statusCode = response.statusCode ?? 0;
      final location = response.headers.value('location');
      if (statusCode >= 300 && statusCode < 400) {
        if (location == null || location.isEmpty) return response;
        final nextUri = currentUri.resolve(location);
        if (currentUri.scheme == 'https' && nextUri.scheme == 'http') {
          // 部分站点（移动站）用 http 重定向：允许降级，但必须清除
          // Cookie/Authorization 等敏感头，避免凭据明文泄露（MITM 面）
          activeHeaders = _sanitizeRedirectHeaders(activeHeaders);
        }
        if (nextUri.scheme != currentUri.scheme ||
            nextUri.host.toLowerCase() != currentUri.host.toLowerCase() ||
            nextUri.port != currentUri.port) {
          activeHeaders = _sanitizeRedirectHeaders(activeHeaders);
        }
        // HTTP 语义：301/302/303 重定向后 POST 应转为 GET 并丢弃 body；
        // 仅 307/308 保持原方法与 body
          if (statusCode == 301 || statusCode == 302 || statusCode == 303) {
            method = 'GET';
            data = null;
            // 转 GET 后无 body：移除表单 Content-Type，避免无 body 仍声明
            // application/x-www-form-urlencoded 引起严格代理/服务端告警
            if (activeHeaders != null &&
                activeHeaders.containsKey('Content-Type')) {
              activeHeaders = Map<String, String>.from(activeHeaders)
                ..remove('Content-Type');
              if (activeHeaders.isEmpty) activeHeaders = null;
            }
          }
        current = nextUri.toString();
        currentUri = nextUri;
        continue;
      }
      return response;
    }
    throw StateError('重定向次数过多');
  }

  static void _assertSafeUrl(String url) {
    if (!_isHttpUrl(url)) {
      throw ArgumentError('不支持的 URL scheme 或地址: $url');
    }
  }

  /// 仅允许 http/https，并阻止直接指向本机、内网和保留地址的 URL。
  static bool _isHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty || host == 'localhost' || host == '::1') return false;
    if (host.startsWith('127.')) return false;
    final ipv4 = _parseIpv4(host);
    if (ipv4 != null) return !_isUnsafeIpv4(ipv4);
    if (host.contains(':')) return !_isUnsafeIpv6(host);
    // 非标准 IP 表示（简写/八进制/十六进制/十进制整数），系统解析器会还原为
    // 私网/回环地址（如 127.1 → 127.0.0.1、2130706433 → 127.0.0.1），一律拒绝。
    if (_looksLikeNumericHost(host)) return false;
    return true;
  }

  /// 形如纯数字/点分数字/十六进制整数的 host，视为可疑的非标准 IP 表示。
  static bool _looksLikeNumericHost(String host) {
    if (RegExp(r'^[0-9]+(\.[0-9]+)*$').hasMatch(host)) return true;
    return RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(host);
  }

  static bool _isUnsafeIpv4(List<int> ipv4) {
    if (ipv4[0] == 0 || ipv4[0] == 10 || ipv4[0] == 127) return true;
    if (ipv4[0] == 172 && ipv4[1] >= 16 && ipv4[1] <= 31) return true;
    if (ipv4[0] == 192 && ipv4[1] == 168) return true;
    if (ipv4[0] == 169 && ipv4[1] == 254) return true;
    // CGNAT 100.64.0.0/10 与 benchmark 198.18.0.0/15：非公网可达的保留段
    if (ipv4[0] == 100 && ipv4[1] >= 64 && ipv4[1] <= 127) return true;
    if (ipv4[0] == 198 && (ipv4[1] == 18 || ipv4[1] == 19)) return true;
    return ipv4[0] >= 224;
  }

  static bool _isUnsafeIpv6(String host) {
    final lower = host.replaceAll('[', '').replaceAll(']', '');
    if (lower == '::1') return true;
    if (lower.startsWith('::ffff:')) {
      final tail = lower.substring(7);
      // 点分十进制映射：::ffff:127.0.0.1
      final ipv4 = _parseIpv4(tail);
      if (ipv4 != null) return _isUnsafeIpv4(ipv4);
      // 十六进制对映射：::ffff:7f00:1（= 127.0.0.1）
      final parts = tail.split(':');
      if (parts.length == 2) {
        final mapped = _ipv4FromHexPair(parts[0], parts[1]);
        if (mapped != null) return _isUnsafeIpv4(mapped);
      }
    }
    // 完整 8 组 IPv6（Dart Uri 不压缩，需显式处理）：
    // IPv4 映射 0:0:0:0:0:ffff:<v4> 与回环 0:0:0:0:0:0:0:1
    if (lower.contains(':') && !lower.contains('::')) {
      final groups = lower.split(':');
      if (groups.length >= 7 && groups.take(5).every((g) => g == '0') && groups[5] == 'ffff') {
        List<int>? mapped;
        if (groups.length == 8) {
          mapped = _ipv4FromHexPair(groups[6], groups[7]);
        } else if (groups.length == 7) {
          mapped = _parseIpv4(groups[6]);
        }
        if (mapped != null) return _isUnsafeIpv4(mapped);
      }
      if (groups.length == 8 &&
          groups.take(7).every((g) => g == '0') &&
          groups[7] == '1') {
        return true; // ::1 完整形式
      }
    }
    if (lower.startsWith('::')) {
      final ipv4 = _parseIpv4(lower.substring(2));
      if (ipv4 != null) return _isUnsafeIpv4(ipv4);
    }
    if (lower.startsWith('fc') || lower.startsWith('fd')) return true;
    if (lower.startsWith('fe8') ||
        lower.startsWith('fe9') ||
        lower.startsWith('fea') ||
        lower.startsWith('feb')) {
      return true;
    }
    return false;
  }

  /// 将两个十六进制组（各 0~FFFF）拼成 IPv4 地址
  static List<int>? _ipv4FromHexPair(String hiHex, String loHex) {
    final hi = int.tryParse(hiHex, radix: 16);
    final lo = int.tryParse(loHex, radix: 16);
    if (hi == null || lo == null || hi > 0xFFFF || lo > 0xFFFF) return null;
    return [hi >> 8, hi & 0xFF, lo >> 8, lo & 0xFF];
  }

  static Map<String, String>? _sanitizeRedirectHeaders(Map<String, String>? headers) {
    if (headers == null) return null;
    // content-type 为非敏感请求头：跨域重定向后仍可能以 POST 重发 body（307/308）
    const allowed = {'accept', 'accept-language', 'user-agent', 'accept-encoding', 'connection', 'content-type'};
    final sanitized = <String, String>{};
    for (final entry in headers.entries) {
      if (allowed.contains(entry.key.toLowerCase())) {
        sanitized[entry.key] = entry.value;
      }
    }
    return sanitized.isEmpty ? null : sanitized;
  }

  static List<int>? _parseIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final result = <int>[];
    for (final part in parts) {
      // 前导零是八进制表示（如 0177 = 127.0.0.1），非标准点分十进制。
      // 拒绝按 IP 解析，使其落入 _looksLikeNumericHost 被拦截。
      if (part.length > 1 && part.startsWith('0')) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      result.add(value);
    }
    return result;
  }
}
