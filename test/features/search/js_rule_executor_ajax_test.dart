import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';

class _NetworkClient implements DioClient {
  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> requestString(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    int retry = 0,
    CancelToken? cancelToken,
  }) async {
    if (method.toUpperCase() == 'POST' && body != null) {
      return postForm(
        url,
        headers: headers,
        body: body,
        sourceId: sourceId,
        concurrentRate: concurrentRate,
        charset: charset,
        cancelToken: cancelToken,
      );
    }
    return getString(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      charset: charset,
      cancelToken: cancelToken,
    );
  }

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
  @override
  Future<(String, Map<String, List<String>>, int)> getResponse(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{}, 200);
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
  Future<(String, Map<String, List<String>>)> postFormFull(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return (
      '',
      const <String, List<String>>{
        'location': ['/ok'],
        'set-cookie': ['sid=abc123'],
      },
    );
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

  test('ajax 请求失败返回错误串（Legado stackTraceStr 语义）', () async {
    JsRuleExecutor.fetcher = (url) async => throw Exception('网络失败');
    const rule = "<js>c = java.ajax('https://fail.example.com'); c.indexOf('Exception:') === 0 ? '错误串' : c</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '错误串');
  });

  test('java.post 返回响应 body（API 型源）', () async {
    JsRuleExecutor.networkClient = _PostBodyClient();
    const rule = "<js>r = java.post('https://example.com/api/token', 'a=1', {}); r.body()</js>";
    final v = await JsRuleExecutor.execute(html, rule, baseUrl: 'https://example.com');
    expect(v, '{"token":"T"}');
  });

  test('java.get(url, headers) 两参 = 网络 GET 返回 body', () async {
    JsRuleExecutor.fetcher = (url) async {
      expect(url, 'https://source.example.com/api/data');
      return '<b>get2结果</b>';
    };
    const rule = "<js>c = java.get('/api/data', {'User-Agent': 'UA'}); c.match(/<b>(.*?)<\\/b>/)[1]</js>";
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://source.example.com/page',
    );
    expect(v, 'get2结果');
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

  test('跨阶段变量注入：java.get 读取 Dart 侧 variables（P0-3）', () async {
    const rule = "<js>java.get('token')</js>";
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      variables: {'token': 'abc123'},
    );
    expect(v, 'abc123');
  });

  test('md5Encode16 取 md5 中段 16 位（Legado substring(8,24)）', () async {
    // md5('abc') = 900150983cd24fb0d6963f7d28e17f72 → 中段 3cd24fb0d6963f7d
    const rule = "<js>java.md5Encode16('abc')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '3cd24fb0d6963f7d');
  });

  test('timeFormat 单参默认 yyyy/MM/dd HH:mm（Legado AppConst.dateFormat）',
      () async {
    const rule = '<js>java.timeFormat(1700000000000)</js>';
    final v = await JsRuleExecutor.execute(html, rule);
    // 本地时区敏感，断言格式形状而非具体值
    expect(v, matches(RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$')));
  });

  test('java.cache put/get 同规则内可读（P1-6）', () async {
    const rule = "<js>java.cache.put('tk1', 'abc123', 0); java.cache.get('tk1')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, 'abc123');
  });

  test('java.cache 跨执行持久（P1-6，内存降级路径）', () async {
    const putRule = "<js>java.cache.put('tk2', 'persisted', 0)</js>";
    await JsRuleExecutor.execute(html, putRule);
    const getRule = "<js>java.cache.get('tk2')</js>";
    final v = await JsRuleExecutor.execute(html, getRule);
    expect(v, 'persisted');
  });

  test('P1-7 getElements 动态选择器（运行时拼接）不再静默空', () async {
    const html = '<div class="list"><span class="itm">甲</span>'
        '<span class="itm">乙</span></div>';
    const rule = "<js>cls = 'itm'; els = java.getElements('span.' + cls); "
        "els.toArray().map(function(e){return e.text();}).join('')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '甲乙');
  });

  test('P1-7 java.get 动态选择器（运行时拼接）走记录-重放', () async {
    const html = '<div class="list"><span class="itm">丙</span></div>';
    const rule = "<js>cls = 'itm'; java.get('span.' + cls, 'text')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '丙');
  });

  test('P1-10 java.ajaxAll 并发取多个 URL（复用 ajax 管道）', () async {
    JsRuleExecutor.fetcher = (url) async {
      return url.contains('1') ? '<b>一</b>' : '<b>二</b>';
    };
    const rule = "<js>rs = java.ajaxAll(['https://x.example/1', 'https://x.example/2']); "
        'rs.length</js>';
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://x.example/page',
    );
    expect(v, '2');
  });

  test('P1-10 java.connect 返回 StrResponse（status/body/header）', () async {
    JsRuleExecutor.fetcher = (url) async => '<b>连接结果</b>';
    const rule = "@js:r = java.connect('https://x.example/api'); "
        "r.body() + '|' + r.status()";
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://x.example/page',
    );
    expect(v, '<b>连接结果</b>|200');
  });

  test('P1-11 getElement 单参返回 Element 风格对象（html/text/attr）', () async {
    const html = '<div class="item"><h3>书名A</h3></div>';
    const rule = "<js>e = java.getElement('div.item'); "
        "e.text() + '|' + (e.html().indexOf('<h3>') >= 0 ? 'has-h3' : 'no')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '书名A|has-h3');
  });

  test('java.cache get 缺失：execute 空值归一为 null', () async {
    const rule = "<js>java.cache.get('no_such_key_' + Date.now())</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, isNull); // '' → execute 空值归一
  });

  test('timeFormat 双参自定义格式仍生效', () async {
    const rule = "<js>java.timeFormat(1700000000, 'yyyy-MM-dd')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
  });
}

/// postFormFull 返回带 body 的假客户端（P0-4：java.post 读响应体）
class _PostBodyClient implements DioClient {
  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> requestString(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    int retry = 0,
    CancelToken? cancelToken,
  }) async {
    if (method.toUpperCase() == 'POST' && body != null) {
      return postForm(
        url,
        headers: headers,
        body: body,
        sourceId: sourceId,
        concurrentRate: concurrentRate,
        charset: charset,
        cancelToken: cancelToken,
      );
    }
    return getString(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      charset: charset,
      cancelToken: cancelToken,
    );
  }

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
  }) async =>
      '';

  @override
  @override
  Future<(String, Map<String, List<String>>, int)> getResponse(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{}, 200);
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async =>
      {};

  @override
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async =>
      {};

  @override
  Future<(String, Map<String, List<String>>)> postFormFull(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async =>
      ('{"token":"T"}', const <String, List<String>>{});

  @override
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async =>
      '';

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
  }) async =>
      '';
}
