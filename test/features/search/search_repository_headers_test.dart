import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/core/data/cookie_jar_service.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/search/data/repositories/search_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

class _HeaderCapturingClient implements DioClient {
  Map<String, String>? lastHeaders;
  String? lastPostUrl;
  String? lastPostBody;
  String? lastPostCharset;
  String? lastGetCharset;
  String? lastGetUrl;
  int getCallCount = 0;
  String responseHtml = '''
    <div class="item">
      <h3 class="title">测试书</h3>
      <a class="detail" href="https://example.com/book/1">详情</a>
    </div>
  ''';

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    lastHeaders = headers;
    lastGetCharset = charset;
    lastGetUrl = url;
    getCallCount++;
    return responseHtml;
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

    @override
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

@override
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    lastPostUrl = url;
    lastPostBody = body;
    lastPostCharset = charset;
    lastHeaders = headers;
    return '''
      <div class="item">
        <h3 class="title">测试书</h3>
        <a class="detail" href="https://example.com/book/1">详情</a>
      </div>
    ''';
  }

@override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    return '';
  }
}

class _FakeCookieJar extends CookieJarService {
  String? stored;

  @override
  Future<String?> get(String sourceId) async => stored;

  @override
  Future<void> set(String sourceId, String cookie) async {
    stored = cookie;
  }

  @override
  Future<void> remove(String sourceId) async {
    stored = null;
  }
}

void main() {
  test('search should pass source headers and cookie to request', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src1',
      name: '测试源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail',
        'header': '{"X-Custom": "1"}',
        'cookie': 'session=abc',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results, isNotEmpty);
    expect(client.lastHeaders, isNotNull);
    expect(client.lastHeaders!['X-Custom'], '1');
    expect(client.lastHeaders!['Cookie'], 'session=abc');
    expect(client.lastHeaders!['Referer'], 'https://example.com');
  });

  test('POST search format should use postForm with form body and charset', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src2',
      name: 'POST源',
      bookSourceUrl: 'https://www.example.com',
      rules: {
        // Legado POST 格式：URL,{json 参数}
        'searchUrl':
            "/modules/search.php,{'charset':'gbk','body':'searchkey={{key}}&type=all','method':'POST'}",
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail',
      },
    );

    final results = await repo.searchWithSource('小说', source);
    expect(results, isNotEmpty);
    // 相对路径基于书源域名拼接
    expect(client.lastPostUrl, 'https://www.example.com/modules/search.php');
    // body 中 {{key}} 表单编码替换
    expect(client.lastPostBody, 'searchkey=%E5%B0%8F%E8%AF%B4&type=all');
    expect(client.lastPostCharset, 'gbk');
  });

  test('GET search with legacy comma syntax without body should stay GET', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src3',
      name: 'GET源',
      bookSourceUrl: 'https://www.example.com',
      rules: {
        'searchUrl': 'https://www.example.com/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results, isNotEmpty);
    expect(client.lastPostUrl, isNull); // 未走 POST
  });

  test('GET search passes book source charset', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src4',
      name: 'GBK源',
      bookSourceUrl: 'https://www.example.com',
      rules: {
        'searchUrl': '/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail',
        'charset': 'gbk',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results, isNotEmpty);
    expect(client.lastGetCharset, 'gbk');
  });

  test('searchWithSource page 替换 GET {{page}}', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src4p',
      name: '分页源',
      bookSourceUrl: 'https://www.example.com',
      rules: {
        'searchUrl': '/search?q={{key}}&page={{page}}',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail@href',
      },
    );

    final results = await repo.searchWithSource('测试', source, page: 3);
    expect(results, isNotEmpty);
    expect(
      client.lastGetUrl,
      'https://www.example.com/search?q=%E6%B5%8B%E8%AF%95&page=3',
    );
  });

  test('searchWithSource page 替换 POST body {{page}}', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src4post',
      name: 'POST分页源',
      bookSourceUrl: 'https://www.example.com',
      rules: {
        'searchUrl':
            "/modules/search.php,{'charset':'utf-8','body':'key={{key}}&page={{page}}','method':'POST'}",
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail@href',
      },
    );

    final results = await repo.searchWithSource('测试', source, page: 2);
    expect(results, isNotEmpty);
    expect(
      client.lastPostBody,
      'key=%E6%B5%8B%E8%AF%95&page=2',
    );
  });

  test('相对详情 URL 基于搜索结果页 resolve', () async {
    final client = _HeaderCapturingClient()
      ..responseHtml = '''
        <div class="item">
          <h3 class="title">测试书</h3>
          <a class="detail" href="/book/2">详情</a>
        </div>
      ''';
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src5',
      name: '相对源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail@href',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results.single.detailUrl, 'https://example.com/book/2');
  });

  test('完整 JS bookList 返回 JSON 数组时解析结果', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src6',
      name: 'JS列表源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': r"<js>JSON.stringify([{name:'书A', url:'/book/a'}])</js>",
        'bookName': r'$.name',
        'bookDetailUrl': r'$.url',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results.single.name, '书A');
    expect(results.single.detailUrl, 'https://example.com/book/a');
  });

  test(r'JSONPath $.data 列表与 URL 模板插值', () async {
    final client = _HeaderCapturingClient()
      ..responseHtml =
          '{"data":[{"book_name":"书A","book_id":"123","kind":"玄幻","last_chapter":"第1章"}]}';
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src7',
      name: 'JSON源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': r'$.data',
        'bookName': r'$.book_name',
        'bookDetailUrl': r'/detail?book_id={{$.book_id}}',
        'kind': r'$.kind',
        'lastChapter': r'$.last_chapter',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results.single.name, '书A');
    expect(results.single.detailUrl, 'https://example.com/detail?book_id=123');
    expect(results.single.kind, '玄幻');
    expect(results.single.lastChapter, '第1章');
  });

  test(r'@put/@get 变量从搜索字段传递到详情 URL', () async {
    final client = _HeaderCapturingClient()
      ..responseHtml = '{"data":[{"id":"123","name":"书A"}]}';
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'srcVar',
      name: '变量源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': r'$.data',
        'bookName': r'$.name',
        // 变量在后面的字段写入，详情 URL 仍能引用（预收集）
        'bookDetailUrl': r'/detail?id=@get:{book}',
        'lastChapter': r'$.name@put:{book:$.id}',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results.single.detailUrl, 'https://example.com/detail?id=123');
    expect(results.single.variables, {'book': '123'});
  });

  test(r'JS 列表规则 java.put 变量供详情 URL @get', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'srcJsVar',
      name: 'JS变量源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList':
            r"<js>java.put('book','123'); JSON.stringify([{name:'书A'}])</js>",
        'bookName': r'$.name',
        'bookDetailUrl': r'/detail?id=@get:{book}',
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results.single.detailUrl, 'https://example.com/detail?id=123');
    expect(results.single.variables, {'book': '123'});
  });

  test('exploreWithSource 支持发现页分页与规则提取', () async {
    final client = _HeaderCapturingClient()
      ..responseHtml = '{"data":[{"book_name":"发现书","id":"7"}]}';
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src8',
      name: '发现源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'exploreUrl': '/discover?page={{page}}',
        'bookList': r'$.data',
        'bookName': r'$.book_name',
        'bookDetailUrl': r'/book/{{$.id}}',
      },
    );

    final results = await repo.exploreWithSource(
      source,
      source.exploreUrl!,
      page: 2,
    );
    expect(client.lastGetUrl, 'https://example.com/discover?page=2');
    expect(results.single.name, '发现书');
    expect(results.single.detailUrl, 'https://example.com/book/7');
  });

  test('debugSearch 返回原始响应与解析示例', () async {
    final client = _HeaderCapturingClient()
      ..responseHtml = '{"data":[{"book_name":"调试书"}]}';
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src9',
      name: '调试源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': r'$.data',
        'bookName': r'$.book_name',
      },
    );

    final debug = await repo.debugSearch('测试', source);
    expect(debug.success, isTrue);
    expect(debug.rawHtml, contains('book_name'));
    expect(debug.results.single.name, '调试书');
  });

  test('loginCheckJs 可更新 Cookie 并替换响应体', () async {
    final client = _HeaderCapturingClient()
      ..responseHtml = '<div class="blocked">需要登录</div>';
    final cookieJar = _FakeCookieJar();
    final repo = SearchRepositoryImpl(client: client, cookieJar: cookieJar);
    const source = BookSource(
      id: 'src-login',
      name: '登录源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail',
        'loginCheckJs': "@js:cookie.setCookie(source.getKey(), 'session=xyz'); "
            "'<div class=\"item\"><h3 class=\"title\">登录后书名</h3></div>'",
      },
    );

    final results = await repo.searchWithSource('测试', source);
    expect(results, isNotEmpty);
    expect(results.single.name, '登录后书名');
    expect(cookieJar.stored, 'session=xyz');
  });

  test('exploreWithSource 支持 loginCheckJs 替换响应体', () async {
    final client = _HeaderCapturingClient()
      ..responseHtml = '<div class="blocked">需要登录</div>';
    final cookieJar = _FakeCookieJar();
    final repo = SearchRepositoryImpl(client: client, cookieJar: cookieJar);
    const source = BookSource(
      id: 'src-explore-login',
      name: '发现登录源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'exploreUrl': '/rank',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail',
        'loginCheckJs': "@js:cookie.setCookie(source.getKey(), 'session=xyz'); "
            "'<div class=\"item\"><h3 class=\"title\">发现书</h3></div>'",
      },
    );

    final results = await repo.exploreWithSource(source, '/rank');
    expect(results, isNotEmpty);
    expect(results.single.name, '发现书');
    expect(cookieJar.stored, 'session=xyz');
  });

  test('debugSearch 只请求一次书源', () async {
    final client = _HeaderCapturingClient();
    final repo = SearchRepositoryImpl(client: client);
    const source = BookSource(
      id: 'src-debug-once',
      name: '单次调试源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'searchUrl': 'https://example.com/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3.title',
        'bookDetailUrl': 'a.detail',
      },
    );

    final debug = await repo.debugSearch('测试', source);
    expect(debug.success, isTrue);
    expect(client.getCallCount, 1);
    expect(debug.results, isNotEmpty);
  });
}
