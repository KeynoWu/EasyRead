import 'package:dio/dio.dart';

/// 自动重试 — 网络异常时最多重试 3 次，间隔递增
class RetryInterceptor extends Interceptor {
  final int _maxRetries;
  final Duration _baseDelay;

  RetryInterceptor({int maxRetries = 3, Duration? baseDelay})
      : _maxRetries = maxRetries,
        _baseDelay = baseDelay ?? const Duration(seconds: 1);

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
      final response = await Dio().fetch(options);
      handler.resolve(response);
    } catch (e) {
      handler.next(err);
    }
  }
}
