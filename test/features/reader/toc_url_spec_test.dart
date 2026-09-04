import 'package:dio/dio.dart';
import 'package:easy_read/core/data/cookie_jar_service.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

/// 捕获请求方法/headers/body 的 mock（P1：tocUrl URL,{json} 选项 + 全 JS URL）
class _CapturingClient implements DioClient {
  _CapturingClient(this.responder);

  final String Function(String url) responder;

  String? lastUrl;
  String? lastMethod;
  Map<String, String>? lastHeaders;
  String? lastBody;
  String? lastCharset;

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
    lastUrl = url;
    lastMethod = method;
    lastHeaders = headers;
    lastBody = body;
    lastCharset = charset;
    return responder(url);
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
      requestString(
        url,
        headers: headers,
        sourceId: sourceId,
        concurrentRate: concurrentRate,
        charset: charset,
        cancelToken: cancelToken,
      );

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
      requestString(
        url,
        method: 'POST',
        headers: headers,
        body: body,
        sourceId: sourceId,
        concurrentRate: concurrentRate,
        charset: charset,
        cancelToken: cancelToken,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SourceRepo implements BookSourceRepository {
  _SourceRepo(this.source);

  final BookSource source;

  @override
  Future<BookSource?> getById(String id) async => source;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeCookieJar extends CookieJarService {
  @override
  Future<String?> get(String sourceId) async => null;

  @override
  Future<void> set(String sourceId, String cookie) async {}

  @override
  Future<void> remove(String sourceId) async {}
}

const _tocJson = '{"data":[{"title":"第一章","item_id":"a"}]}';

void main() {
  test('tocUrl 支持 URL,{json} 选项（POST/headers/body/charset）', () async {
    const source = BookSource(
      id: 'src1',
      name: '测试源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'ruleBookInfo': {
          'init': r'$.data',
          'tocUrl':
              r'https://api.example.com/toc,{"method":"POST","body":"bid={{$.book_id}}","headers":{"X-Toc":"1"},"charset":"utf-8"}',
        },
        'ruleToc': {
          'chapterList': r'$.data',
          'chapterName': r'$.title',
          'chapterUrl': r'/content?item_id={{$.item_id}}',
        },
      },
    );
    final client = _CapturingClient((url) =>
        url.contains('/book/') ? '{"data":{"book_id":"1"}}' : _tocJson);
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(source),
      cookieJar: _FakeCookieJar(),
    );

    final catalog = await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    expect(catalog.chapters.single.title, '第一章');
    // 选项解析：URL 剥离、POST、body 模板已展开、headers 合并、charset 透传
    expect(client.lastUrl, 'https://api.example.com/toc');
    expect(client.lastMethod, 'POST');
    expect(client.lastBody, 'bid=1');
    expect(client.lastHeaders!['X-Toc'], '1');
    expect(client.lastCharset, 'utf-8');
  });

  test('tocUrl 全 JS URL（规则提取值内嵌 @js: 段）', () async {
    const source = BookSource(
      id: 'src2',
      name: 'JS源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'ruleBookInfo': {
          'init': r'$.data',
          // 规则提取出的 tocUrl 值本身含 JS 段 → AnalyzeUrl 层求值
          'tocUrl': r'$.toc_url',
        },
        'ruleToc': {
          'chapterList': r'$.data',
          'chapterName': r'$.title',
          'chapterUrl': r'/content?item_id={{$.item_id}}',
        },
      },
    );
    final client = _CapturingClient((url) => url.contains('/book/')
        ? '{"data":{"book_id":"1",'
            '"toc_url":"@js:\\"https://api.example.com/toc?ref=\\" + baseUrl"}}'
        : _tocJson);
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(source),
      cookieJar: _FakeCookieJar(),
    );

    final catalog = await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src2',
      detailUrl: 'https://example.com/book/1',
    );
    expect(catalog.chapters.single.title, '第一章');
    expect(
      client.lastUrl,
      'https://api.example.com/toc?ref=https://example.com',
    );
    expect(client.lastMethod, 'GET');
  });
}
