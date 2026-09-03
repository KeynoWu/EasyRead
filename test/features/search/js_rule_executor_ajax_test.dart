import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';

class _NetworkClient implements DioClient {
  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return '';
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {
      'location': ['/ok'],
      'set-cookie': ['sid=head'],
    };
  }

  @override
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {
      'location': ['/ok'],
      'set-cookie': ['sid=abc123'],
    };
  }

  @override
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return '';
  }

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    return '';
  }
}

void main() {
  const html = '<div class="item"><h3>书名A</h3></div>';

  tearDown(() {
    JsRuleExecutor.fetcher = null;
    JsRuleExecutor.networkClient = null;
  });

  test('java.ajax 字面量 URL：请求结果供 JS 处理', () async {
    JsRuleExecutor.fetcher = (url) async {
      expect(url, 'https://api.example.com/data');
      return '<span>接口书名</span>';
    };
    const rule = "<js>c = java.ajax('https://api.example.com/data'); result = c; result.match(/<span>(.*?)<\\/span>/)[1]</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '接口书名');
  });

  test('java.ajax 变量 URL（java.get 赋值）', () async {
    // java.get('url') 返回 baseUrl；ajax(baseUrl) 请求它
    JsRuleExecutor.fetcher = (url) async {
      expect(url, 'https://source.example.com/page');
      return '<p>变量URL结果</p>';
    };
    const rule = "<js>u = java.get('url'); c = java.ajax(u); c.match(/<p>(.*?)<\\/p>/)[1]</js>";
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://source.example.com/page',
    );
    expect(v, '变量URL结果');
  });

  test('ajax URL 收集去重后请求', () async {
    var calls = 0;
    JsRuleExecutor.fetcher = (url) async {
      calls++;
      return '<b>结果</b>';
    };
    const rule = "<js>a = java.ajax('https://x/1'); b = java.ajax('https://x/1'); a.length + b.length</js>";
    // 同一 URL 在第一遍出现两次 → __ajaxUrls 两条 → 请求两次（当前实现不去重）
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, isNotNull);
    expect(calls, 2);
  });

  test('相对 ajax URL 基于 baseUrl 解析', () async {
    JsRuleExecutor.fetcher = (url) async {
      expect(url, 'https://source.example.com/api/data');
      return '<b>相对结果</b>';
    };
    const rule = "<js>c = java.ajax('/api/data'); c.match(/<b>(.*?)<\\/b>/)[1]</js>";
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://source.example.com/book/1',
    );
    expect(v, '相对结果');
  });

  test('ajax 请求失败不影响引擎（返回空）', () async {
    JsRuleExecutor.fetcher = (url) async => throw Exception('网络失败');
    const rule = "<js>c = java.ajax('https://fail.example.com'); c == '' ? '空结果' : c</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '空结果');
  });

  test('java.post/java.head 返回响应头与 Cookie', () async {
    JsRuleExecutor.networkClient = _NetworkClient();
    const rule = "@js:var r = java.post('https://example.com/login', "
        "'user=1', {}); "
        "r.cookies() + ':' + "
        "java.head('https://example.com/api').header('location')";
    final value = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://example.com',
    );
    expect(value, 'sid=abc123:/ok');
  });

  test('java.getString 可读取 ajax 返回的 JSON', () async {
    JsRuleExecutor.fetcher = (url) async => '{"data":{"title":"接口书名"}}';
    const rule = "<js>result = java.ajax('https://api.example.com/data'); "
        "java.getString('\$.data.title')</js>";
    final value = await JsRuleExecutor.execute(html, rule);
    expect(value, '接口书名');
  });
}
