import 'package:dio/dio.dart';

/// 请求频率控制 — 每个书源独立 QPS 限制
class RateLimitInterceptor extends Interceptor {
  final Map<String, DateTime> _lastRequestTime = {};
  final int _minIntervalMs;

  RateLimitInterceptor({int minIntervalMs = 1000}) : _minIntervalMs = minIntervalMs;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final sourceKey = options.extra['source_id'] as String? ?? 'default';
    final lastTime = _lastRequestTime[sourceKey];
    if (lastTime != null) {
      final elapsed = DateTime.now().difference(lastTime).inMilliseconds;
      if (elapsed < _minIntervalMs) {
        Future.delayed(Duration(milliseconds: _minIntervalMs - elapsed), () {
          _lastRequestTime[sourceKey] = DateTime.now();
          handler.next(options);
        });
        return;
      }
    }
    _lastRequestTime[sourceKey] = DateTime.now();
    handler.next(options);
  }
}
