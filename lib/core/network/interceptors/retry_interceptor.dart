import 'package:dio/dio.dart';

/// 自动重试 — 网络异常时最多重试 3 次，间隔递增。
/// 复用原 Dio 实例重试，保证 UA/限频等拦截器与超时配置仍然生效。
class RetryInterceptor extends Interceptor {
  final Dio _dio;
  final int _maxRetries;
  final Duration _baseDelay;

  RetryInterceptor(
    this._dio, {
    int maxRetries = 3,
    Duration? baseDelay,
    // ignore: prefer_initializing_formals — 私有字段不能作为命名参数，必须经公开参数赋值
  })  : _maxRetries = maxRetries,
        _baseDelay = baseDelay ?? const Duration(seconds: 1);

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final retryCount = (err.requestOptions.extra['retry_count'] as int?) ?? 0;
    // 显式标记 no_retry 的请求（如订阅批量更新）不参与自动重试，
    // 避免长任务被重试放大数倍时长
    if (err.requestOptions.extra['no_retry'] == true ||
        retryCount >= _maxRetries ||
        !_isRetryable(err)) {
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

  static bool _isRetryable(DioException err) {
    if (err.type == DioExceptionType.cancel) return false;
    if (err.type == DioExceptionType.badResponse) {
      final statusCode = err.response?.statusCode ?? 0;
      return statusCode == 408 || statusCode == 429 || statusCode >= 500;
    }
    return err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout;
  }
}
