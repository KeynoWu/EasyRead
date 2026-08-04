import 'dart:async';
import 'package:dio/dio.dart';

/// 请求频率控制 — 每个书源独立 QPS 限制。
/// 同一书源的请求串行排队，保证相邻请求间隔 >= minIntervalMs，
/// 避免并发 burst 时多个延迟请求在同一时刻同时发出。
class RateLimitInterceptor extends Interceptor {
  final Map<String, DateTime> _lastRequestTime = {};
  final Map<String, Future<void>> _chain = {};
  final int _minIntervalMs;

  RateLimitInterceptor({this._minIntervalMs = 1000});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final sourceKey = options.extra['source_id'] as String? ?? 'default';
    final prev = _chain[sourceKey] ?? Future.value();
    // catchError 防止链上任一环节异常导致后续请求永久挂起
    final task = prev.catchError((_) {}).then((_) async {
      final now = DateTime.now();
      final last = _lastRequestTime[sourceKey];
      final waitMs = last == null
          ? 0
          : _minIntervalMs - now.difference(last).inMilliseconds;
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
      _lastRequestTime[sourceKey] = DateTime.now();
      handler.next(options);
    });
    _chain[sourceKey] = task;
  }
}
