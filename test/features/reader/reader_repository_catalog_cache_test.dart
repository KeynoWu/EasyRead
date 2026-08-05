import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

class _CatalogClient implements DioClient {
  int catalogCalls = 0;

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
  }) async {
    catalogCalls++;
    return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
  }) async {
    return {};
  }

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    return '';
  }
}

class _SourceRepo implements BookSourceRepository {
  String headerValue = 'token-1';

  @override
  Future<List<BookSource>> getAll() async => [];

  @override
  Future<BookSource?> getById(String id) async {
    return const BookSource(
      id: 'src1',
      name: '源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'chapterList': 'ul > li',
        'chapterName': 'a',
        'chapterUrl': 'a@href',
      },
    ).copyWith(
      rules: {
        'chapterList': 'ul > li',
        'chapterName': 'a',
        'chapterUrl': 'a@href',
        'header': '{"X-Token": "$headerValue"}',
      },
    );
  }

  @override
  Future<void> save(BookSource source) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> importFromJson(String jsonString) async {}
  @override
  Future<void> importFromUrl(String url) async {}
  @override
  Future<List<BookSource>> getEnabled() async => [];
}

void main() {
  test('getCatalog should reuse cached catalog for same book/source', () async {
    final client = _CatalogClient();
    final repo = ReaderRepositoryImpl(client: client, sourceRepo: _SourceRepo());

    await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    final second = await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );

    expect(second.chapters.length, 1);
    expect(client.catalogCalls, 1);
  });

  test('getCatalog should refetch when source headers change', () async {
    final client = _CatalogClient();
    final sourceRepo = _SourceRepo();
    final repo = ReaderRepositoryImpl(client: client, sourceRepo: sourceRepo);

    await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    sourceRepo.headerValue = 'token-2';
    await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );

    expect(client.catalogCalls, 2);
  });
}
