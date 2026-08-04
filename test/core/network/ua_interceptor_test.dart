import 'package:dio/dio.dart';
import 'package:easy_read/core/network/interceptors/ua_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UA 轮换不应修改 const 列表', () {
    final interceptor = UaInterceptor();
    final options = RequestOptions(path: 'https://example.com/sources.json');
    final handler = RequestInterceptorHandler();

    interceptor.onRequest(options, handler);

    expect(options.headers['User-Agent'], isNotNull);
  });
}
