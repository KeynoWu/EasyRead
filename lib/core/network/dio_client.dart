import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
      RetryInterceptor(dio: dio),
    ]);
    return dio;
  }

  factory DioClient() {
    _instance ??= DioClient._();
    return _instance!;
  }

  Dio get dio => _dio;

  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId}) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
    );
    return response.data.toString();
  }

  /// 请求并返回响应头，用于书源登录后捕获 Set-Cookie。
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
    );
    return response.headers.map;
  }

  /// 带下载进度回调的请求（大文件场景使用）
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
      responseType: ResponseType.plain,
      // 大文件下载的空闲判定由 ImportBookSource 控制，
      // 这里用 Duration.zero 禁用 Dio 固定 receiveTimeout，避免其先于上层超时生效。
      receiveTimeout: Duration.zero,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    return response.data.toString();
  }

  Future<Response<dynamic>> _get(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
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
      final response = await _dio.get<dynamic>(
        current,
        options: Options(
          headers: activeHeaders,
          extra: {'source_id': sourceId},
          responseType: responseType ?? ResponseType.json,
          receiveTimeout: receiveTimeout,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode >= 300 && statusCode < 400) {
        final location = response.headers.value('location');
        if (location == null || location.isEmpty) return response;
        final nextUri = currentUri.resolve(location);
        if (currentUri.scheme == 'https' && nextUri.scheme == 'http') {
          throw ArgumentError('禁止 HTTPS 降级重定向: $current -> $nextUri');
        }
        if (nextUri.scheme != currentUri.scheme ||
            nextUri.host.toLowerCase() != currentUri.host.toLowerCase() ||
            nextUri.port != currentUri.port) {
          activeHeaders = _sanitizeRedirectHeaders(activeHeaders);
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
    return true;
  }

  static bool _isUnsafeIpv4(List<int> ipv4) {
    if (ipv4[0] == 0 || ipv4[0] == 10 || ipv4[0] == 127) return true;
    if (ipv4[0] == 172 && ipv4[1] >= 16 && ipv4[1] <= 31) return true;
    if (ipv4[0] == 192 && ipv4[1] == 168) return true;
    if (ipv4[0] == 169 && ipv4[1] == 254) return true;
    return ipv4[0] >= 224;
  }

  static bool _isUnsafeIpv6(String host) {
    final lower = host.replaceAll('[', '').replaceAll(']', '');
    if (lower == '::1') return true;
    if (lower.startsWith('::ffff:')) {
      final ipv4 = _parseIpv4(lower.substring(7));
      if (ipv4 != null) return _isUnsafeIpv4(ipv4);
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

  static Map<String, String>? _sanitizeRedirectHeaders(Map<String, String>? headers) {
    if (headers == null) return null;
    const allowed = {'accept', 'accept-language', 'user-agent', 'accept-encoding', 'connection'};
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
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      result.add(value);
    }
    return result;
  }
}
