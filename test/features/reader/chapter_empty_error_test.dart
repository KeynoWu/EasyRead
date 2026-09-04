import 'dart:io';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:hive/hive.dart';

/// 按 URL 返回不同 HTML 的 mock 客户端（同既有 reader 测试惯例）
class _DynamicClient implements DioClient {
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
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  _DynamicClient(this.responder);

  final String Function(String url) responder;

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
    return responder(url);
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
    return {};
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
    return {};
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
    return ('', const <String, List<String>>{});
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

class _SourceRepo implements BookSourceRepository {
  final BookSource source;
  _SourceRepo(this.source);

  @override
  Future<List<BookSource>> getAll() async => [source];
  @override
  Future<BookSource?> getById(String id) async => source;
  @override
  Future<void> save(BookSource source) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> importFromJson(String jsonString) async {}
  @override
  Future<void> importFromUrl(String url) async {}
  @override
  Future<List<BookSource>> getEnabled() async => [source];
}

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_empty_chapter').path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(ChapterModelAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ReadingProgressModelAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('章节提取为空（M1 核心链路）', () {
    test('正文规则失配且无候选文本时抛 ChapterLoadException，不做整页 HTML 兜底',
        () async {
      const source = BookSource(
        id: 'empty-src',
        name: '空正文源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          // 正文规则失配；页面正文候选文本均 < 200 字（不满足智能提取阈值）
          'chapterContent': '.content@text',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        // 正文页：无任何文本节点，CSS 规则与智能提取均无结果 → 提取为空
        return '<html><head><meta charset="utf-8"></head><body></body></html>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      await expectLater(
        repo.getChapter(
          bookId: 'book1',
          chapterIndex: 0,
          sourceId: 'empty-src',
          detailUrl: 'https://example.com/book/1',
        ),
        throwsA(
          isA<ChapterLoadException>()
              .having((e) => e.message, 'message', contains('章节内容为空或解析失败')),
        ),
      );
    });

    test('正文规则命中时正常返回，不受空提取兜底影响', () async {
      const source = BookSource(
        id: 'ok-src',
        name: '正常源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'chapterContent': '.content@text',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        return '<div class="content"><p>正常正文内容。</p></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'ok-src',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('正常正文内容'));
    });

    test('§三-2 源规则层失败 → ChapterErrorKind.sourceError（可自动换源）',
        () async {
      const source = BookSource(
        id: 'kind-empty',
        name: '空正文源',
        bookSourceUrl: 'https://example.com',
        rules: {'chapterContent': '.content@text'},
      );
      final client = _DynamicClient(
        (_) => '<html><head></head><body></body></html>',
      );
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      await expectLater(
        repo.getChapter(
          bookId: 'book1',
          chapterIndex: 0,
          sourceId: 'kind-empty',
          detailUrl: 'https://example.com/book/1',
        ),
        throwsA(
          isA<ChapterLoadException>().having(
            (e) => e.kind,
            'kind',
            ChapterErrorKind.sourceError,
          ),
        ),
      );
    });

    test('§三-7 loginCheckJs error: 前缀 → 登录失效 sourceError（可换源）',
        () async {
      const source = BookSource(
        id: 'login-expired',
        name: '登录失效源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterContent': '.content@text',
          'loginCheckJs': 'error:请先登录',
        },
      );
      final client = _DynamicClient(
        (_) => '<div class="content"><p>正文</p></div>',
      );
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      await expectLater(
        repo.getChapter(
          bookId: 'book1',
          chapterIndex: 0,
          sourceId: 'login-expired',
          detailUrl: 'https://example.com/book/1',
        ),
        throwsA(
          isA<ChapterLoadException>()
              .having((e) => e.kind, 'kind', ChapterErrorKind.sourceError)
              .having((e) => e.message, 'message', contains('登录已失效')),
        ),
      );
    });

    test('§三-2 瞬时网络异常 → ChapterErrorKind.networkError（不触发自动换源）',
        () async {
      const source = BookSource(
        id: 'kind-net',
        name: '网络源',
        bookSourceUrl: 'https://example.com',
        rules: {'chapterContent': '.content@text'},
      );
      final client = _ThrowingClient();
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      await expectLater(
        repo.getChapter(
          bookId: 'book1',
          chapterIndex: 0,
          sourceId: 'kind-net',
          detailUrl: 'https://example.com/book/1',
        ),
        throwsA(
          isA<ChapterLoadException>()
              .having((e) => e.kind, 'kind', ChapterErrorKind.networkError)
              .having((e) => e.message, 'message', contains('网络')),
        ),
      );
    });
  });
}

/// 请求层直接抛 DioException 的客户端（模拟超时/断网）
class _ThrowingClient implements DioClient {
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
  }) async => getString(url);

  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    throw DioException.connectionError(
      requestOptions: RequestOptions(path: url),
      reason: 'timeout',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
