import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/search/data/repositories/search_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

class _HeaderCapturingClient implements DioClient {
  Map<String, String>? lastHeaders;
  String? lastPostUrl;
  String? lastPostBody;
  String? lastPostCharset;

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    lastHeaders = headers;
    return '''
      <div class="item">
        <h3 class="title">测试书</h3>
        <a class="detail" href="https://example.com/book/1">详情</a>
      </div>
    ''';
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
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    return '';
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
}