import 'package:dio/dio.dart';

/// 自动重试 — 网络异常时最多重试 3 次，间隔递增。
/// 复用原 Dio 实例重试，保证 UA/限频等拦截器与超时配置仍然生效。
class RetryInterceptor extends Interceptor {
  final Dio _dio;
  final int _maxRetries;
  final Duration _baseDelay;

  RetryInterceptor({
    required this._dio,
    this._maxRetries = 3,
    Duration? baseDelay,
  })  : _baseDelay = baseDelay ?? const Duration(seconds: 1);

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final retryCount = (err.requestOptions.extra['retry_count'] as int?) ?? 0;
    if (retryCount >= _maxRetries) {
      return handler.next(err);
    }
    await Future.delayed(_baseDelay * (retryCount + 1));
    final options = err.requestOptions.copyWith(
      extra: {...err.requestOptions.extra, 'retry_count': retryCount + 1},
    );
    try {
      final response = await _dio.fetch(options);
      handler.resolve(response);
    } catch (e) {
      handler.next(err);
    }
  }
}
