import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('大文件请求不应被全局 receiveTimeout 提前中断', () async {
    final client = DioClient();
    final captured = <RequestOptions>[];
    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        captured.add(options);
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: '[]'),
        );
      },
    );
    client.dio.interceptors.add(interceptor);
    addTearDown(() {
      client.dio.interceptors.remove(interceptor);
    });

    await client.getStringWithProgress('https://example.com/sources.json');

    expect(captured, hasLength(1));
    expect(captured.single.receiveTimeout, Duration.zero);
  });
}
