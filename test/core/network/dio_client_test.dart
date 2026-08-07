import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

class _RedirectAdapter implements HttpClientAdapter {
  int calls = 0;
  Map<String, dynamic>? lastHeaders;
  final String redirectLocation;

  _RedirectAdapter({
    this.redirectLocation = 'https://attacker.example/x',
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (calls == 1) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [redirectLocation],
        },
      );
    }
    lastHeaders = options.headers;
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _JsonAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"name":"规则"}',
      200,
      headers: {'content-type': ['application/json; charset=utf-8']},
    );
  }

  @override
  void close({bool force = false}) {}
}

class _BytesAdapter implements HttpClientAdapter {
  final Uint8List bytes;

  _BytesAdapter(this.bytes);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('DioClient should reject file/data schemes', () async {
    final client = DioClient();
    await expectLater(
      client.getString('file:///etc/passwd'),
      throwsArgumentError,
    );
    await expectLater(
      client.getString('data:text/plain,hello'),
      throwsArgumentError,
    );
  });

  test('DioClient should reject localhost and private network URLs', () async {
    final client = DioClient();
    for (final url in [
      'http://localhost:8080/book',
      'http://127.0.0.1/book',
      'http://10.0.0.1/book',
      'http://172.16.0.1/book',
      'http://192.168.1.1/book',
      'http://169.254.169.254/book',
    ]) {
      await expectLater(client.getString(url), throwsArgumentError, reason: url);
    }
    await expectLater(
      client.getString('http://[::ffff:127.0.0.1]/book'),
      throwsArgumentError,
    );
    await expectLater(
      client.getString('http://[::1]/book'),
      throwsArgumentError,
    );
  });

  test('DioClient should strip sensitive headers on cross-origin redirect', () async {
    final adapter = _RedirectAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioClient.forTesting(dio);

    final result = await client.getStringWithProgress(
      'https://example.com/book',
      headers: {
        'Cookie': 'session=secret',
        'Referer': 'https://example.com',
        'X-Custom': '1',
        'Accept': 'text/html',
      },
    );

    expect(result, 'ok');
    expect(adapter.lastHeaders, isNotNull);
    expect(adapter.lastHeaders!['Cookie'], isNull);
    expect(adapter.lastHeaders!['Referer'], isNull);
    expect(adapter.lastHeaders!['X-Custom'], isNull);
    expect(adapter.lastHeaders!['Accept'], 'text/html');
  });

  test('DioClient should allow HTTPS to HTTP downgrade but strip sensitive headers', () async {
    final adapter = _RedirectAdapter(
      redirectLocation: 'http://example.com/book',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioClient.forTesting(dio);

    // 降级允许（移动站常见），但 Cookie/Authorization 等敏感头必须清除
    final result = await client.getStringWithProgress(
      'https://example.com/book',
    );
    expect(result, isNotNull);
    expect(adapter.lastHeaders!['Cookie'], isNull);
    expect(adapter.lastHeaders!['Referer'], isNull);
  });

  test('getString keeps raw JSON payload', () async {
    final dio = Dio()..httpClientAdapter = _JsonAdapter();
    final client = DioClient.forTesting(dio);

    final content = await client.getString('https://example.com/rules.json');
    final decoded = jsonDecode(content) as Map<String, dynamic>;
    expect(decoded['name'], '规则');
  });

  test('getString decodes GBK response with charset parameter', () async {
    final dio = Dio()
      ..httpClientAdapter = _BytesAdapter(
        Uint8List.fromList(gbk.encode('小说正文')),
      );
    final client = DioClient.forTesting(dio);

    expect(await client.getString('https://example.com/book', charset: 'gbk'), '小说正文');
  });
}
