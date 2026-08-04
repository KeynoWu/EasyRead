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
      RetryInterceptor(),
    ]);
  }

  factory DioClient() {
    _instance ??= DioClient._();
    return _instance!;
  }

  Dio get dio => _dio;

  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId}) async {
    final response = await _dio.get(
      url,
      options: Options(
        headers: headers,
        extra: {'source_id': sourceId},
      ),
    );
    return response.data.toString();
  }
}
