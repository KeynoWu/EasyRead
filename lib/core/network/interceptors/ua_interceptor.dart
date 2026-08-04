import 'package:dio/dio.dart';

/// UA 轮换 — 随机选择一个 User-Agent
class UaInterceptor extends Interceptor {
  static const _userAgents = [
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 13; SM-S9080) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.163 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.6167.101 Mobile Safari/537.36',
  ];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!options.headers.containsKey('User-Agent') && !options.headers.containsKey('user-agent')) {
      options.headers['User-Agent'] = (_userAgents..shuffle()).first;
    }
    handler.next(options);
  }
}
