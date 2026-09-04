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
  final String? contentType;

  _BytesAdapter(this.bytes, {this.contentType});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (contentType != null) {
      return ResponseBody.fromBytes(bytes, 200, headers: {
        Headers.contentTypeHeader: [contentType!],
      });
    }
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

  test('P1-12 UTF-8 BOM 自动剥离', () async {
    final bytes = Uint8List.fromList([
      0xEF, 0xBB, 0xBF, // BOM
      ...utf8.encode('小说正文'),
    ]);
    final dio = Dio()..httpClientAdapter = _Utf16BytesAdapter(bytes);
    final client = DioClient.forTesting(dio);
    expect(await client.getString('https://example.com/book'), '小说正文');
  });

  test('P1-12 Content-Type charset 三级检测（规则缺省时用响应头）', () async {
    final dio = Dio()
      ..httpClientAdapter = _BytesAdapter(
        Uint8List.fromList(gbk.encode('中文GBK')),
        contentType: 'text/html; charset=gbk',
      );
    final client = DioClient.forTesting(dio);
    // 无规则 charset → Content-Type 头 gbk 生效
    expect(await client.getString('https://example.com/book'), '中文GBK');
  });

  test('P1 requestString POST：默认表单 Content-Type，显式头优先', () async {
    final adapter = _MethodCapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioClient.forTesting(dio);

    final out = await client.requestString(
      'https://example.com/api',
      method: 'POST',
      body: 'a=1&b=2',
    );
    expect(out, 'ok');
    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastData, 'a=1&b=2');
    expect(adapter.lastHeaders!['content-type'],
        'application/x-www-form-urlencoded');

    // 显式 Content-Type 优先（JSON body 源自带声明）
    await client.requestString(
      'https://example.com/api',
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: '{"a":1}',
    );
    expect(adapter.lastHeaders!['content-type'], 'application/json');
  });

  test('P1 requestString GET：body 不随 GET 发送', () async {
    final adapter = _MethodCapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioClient.forTesting(dio);

    await client.requestString(
      'https://example.com/api',
      method: 'get',
      body: 'a=1',
    );
    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastData, isNull);
  });

  test('P1 requestString retry：失败 N 次后重试成功', () async {
    final adapter = _MethodCapturingAdapter(failTimes: 2);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = DioClient.forTesting(dio);

    final out = await client.requestString(
      'https://example.com/api',
      retry: 2,
    );
    expect(out, 'ok');
    expect(adapter.calls, 3);

    // 重试次数不足仍抛错
    adapter.calls = 0;
    await expectLater(
      client.requestString('https://example.com/api', retry: 1),
      throwsA(anything),
    );
    expect(adapter.calls, 2);
  });

  test('审查修复：服务器已响应（badResponse）不重试', () async {
    final dio = Dio()..httpClientAdapter = _ServerErrorAdapter();
    final client = DioClient.forTesting(dio);

    await expectLater(
      client.requestString('https://example.com/api', retry: 3),
      throwsA(anything),
    );
    expect(_ServerErrorAdapter.lastCalls, 1, reason: 'badResponse 不应重试');
  });

  test('§三-6 审查修复：取消不重试', () async {
    final dio = Dio()..httpClientAdapter = _CancelAdapter();
    final client = DioClient.forTesting(dio);

    await expectLater(
      client.requestString('https://example.com/api', retry: 3),
      throwsA(anything),
    );
    expect(_CancelAdapter.lastCalls, 1, reason: '取消后不得重发请求');
  });

  test('§三-6 审查修复：UTF-16LE BOM 按 UTF-16 解码（不再按 UTF-8 乱码）', () async {
    const text = '书源正文。';
    final units = text.codeUnits;
    final bytes = <int>[0xFF, 0xFE];
    for (final u in units) {
      bytes..add(u & 0xFF)..add((u >> 8) & 0xFF);
    }
    final dio = Dio()..httpClientAdapter = _Utf16BytesAdapter(bytes);
    final client = DioClient.forTesting(dio);

    final out = await client.requestString('https://example.com/api');
    expect(out, text);
  });

  test('§三-6 审查修复：charset=utf-16be（无 BOM）按大端解码', () async {
    const text = 'AB';
    final bytes = <int>[];
    for (final u in text.codeUnits) {
      bytes..add((u >> 8) & 0xFF)..add(u & 0xFF);
    }
    final dio = Dio()..httpClientAdapter = _Utf16BytesAdapter(bytes);
    final client = DioClient.forTesting(dio);

    final out = await client.requestString(
      'https://example.com/api',
      charset: 'utf-16be',
    );
    expect(out, text);
  });
}

/// 返回预设字节体（charset 解码测试）
class _Utf16BytesAdapter implements HttpClientAdapter {
  _Utf16BytesAdapter(this.body);

  final List<int> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody(Stream.value(Uint8List.fromList(body)), 200);

  @override
  void close({bool force = false}) {}
}

/// 固定 500 响应（badResponse 不重试测试）
class _ServerErrorAdapter implements HttpClientAdapter {
  _ServerErrorAdapter();

  static int lastCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastCalls++;
    return ResponseBody.fromString('err', 500);
  }

  @override
  void close({bool force = false}) {}
}

/// 请求即抛取消（重试过滤测试：取消不得重发）
class _CancelAdapter implements HttpClientAdapter {
  _CancelAdapter();

  static int lastCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastCalls++;
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'cancelled',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MethodCapturingAdapter implements HttpClientAdapter {
  _MethodCapturingAdapter({this.failTimes = 0});

  int failTimes;
  int calls = 0;
  String? lastMethod;
  Object? lastData;
  Map<String, dynamic>? lastHeaders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    lastMethod = options.method;
    lastHeaders = options.headers;
    lastData = options.data is String ? options.data : null;
    if (calls <= failTimes) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'boom',
      );
    }
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}
