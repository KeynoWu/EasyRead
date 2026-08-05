import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/interceptors/retry_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingAdapter implements HttpClientAdapter {
  int calls = 0;
  final int statusCode;

  _CountingAdapter(this.statusCode);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString('', statusCode);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('should not retry 4xx responses', () async {
    final dio = Dio();
    final adapter = _CountingAdapter(404);
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(RetryInterceptor(
      dio: dio,
      maxRetries: 2,
      baseDelay: const Duration(milliseconds: 1),
    ));

    await expectLater(
      dio.get('https://example.com/book'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.calls, 1);
  });

  test('should retry 5xx responses up to max retries', () async {
    final dio = Dio();
    final adapter = _CountingAdapter(500);
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(RetryInterceptor(
      dio: dio,
      maxRetries: 2,
      baseDelay: const Duration(milliseconds: 1),
    ));

    await expectLater(
      dio.get('https://example.com/book'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.calls, 3);
  });
}
