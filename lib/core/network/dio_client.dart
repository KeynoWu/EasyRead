import 'package:dio/dio.dart';
import 'interceptors/rate_limit_interceptor.dart';
import 'interceptors/retry_interceptor.dart';
import 'interceptors/ua_interceptor.dart';

/// 全局 Dio 客户端 — 单例，所有网络请求通过此实例
class DioClient {
  static DioClient? _instance;
  late final Dio _dio;

  DioClient._() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    ));
    _dio.interceptors.addAll([
      UaInterceptor(),
      RateLimitInterceptor(),
      RetryInterceptor(dio: _dio),
    ]);
  }

  factory DioClient() {
    _instance ??= DioClient._();
    return _instance!;
  }

  Dio get dio => _dio;

  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId}) async {
    if (!_isHttpUrl(url)) {
      throw ArgumentError('不支持的 URL scheme: $url');
    }
    final response = await _dio.get(
      url,
      options: Options(
        headers: headers,
        extra: {'source_id': sourceId},
      ),
    );
    return response.data.toString();
  }

  /// 带下载进度回调的请求（大文件场景使用）
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (!_isHttpUrl(url)) {
      throw ArgumentError('不支持的 URL scheme: $url');
    }
    final response = await _dio.get<String>(
      url,
      options: Options(
        headers: headers,
        extra: {'source_id': sourceId},
        responseType: ResponseType.plain,
      ),
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    return response.data.toString();
  }

  /// 仅允许 http/https，阻止 file://、data: 等非预期 scheme（SSRF 防护）
  static bool _isHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}
