import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/core/purification/purify_pipeline.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _CatalogClient implements DioClient {
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
  }) async =>
      '<ul><li><a href="https://example.com/ch/1">第1章</a></li>'
      '<li><a href="https://example.com/ch/2">第2章(广告)</a></li></ul>';

  @override
  Dio get dio => Dio();

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

const _source = BookSource(
  id: 'src1',
  name: '测试源',
  bookSourceUrl: 'https://example.com',
  rules: <String, dynamic>{
    'chapterList': 'ul > li',
    'chapterName': 'a',
    'chapterUrl': 'a@href',
  },
);

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_toc_purify').path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(ChapterModelAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('§三-10 目录标题经用户净化规则（标题作用域）套用', () async {
    final repo = ReaderRepositoryImpl(
      client: _CatalogClient(),
      sourceRepo: _SourceRepo(_source),
      pipeline: PurifyPipeline(
        titlePurifier: const RegexPurifier(
          rules: [PurifyRule(pattern: r'\(广告\)', replacement: '')],
        ),
      ),
    );

    final catalog = await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    expect(catalog.chapters[0].title, '第1章');
    expect(catalog.chapters[1].title, '第2章');
  });

  test('§三-10 改目录标题净化规则后（内存缓存命中）重新取目录即生效', () async {
    final repo = ReaderRepositoryImpl(
      client: _CatalogClient(),
      sourceRepo: _SourceRepo(_source),
      pipeline: PurifyPipeline(
        titlePurifier: const RegexPurifier(
          rules: [PurifyRule(pattern: r'\(广告\)', replacement: '')],
        ),
      ),
    );
    final first = await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    expect(first.chapters[1].title, '第2章');

    // 换新规则实例（模拟用户改规则），同一 repo 内存缓存命中也重新净化
    repo.setPipeline(
      PurifyPipeline(
        titlePurifier: const RegexPurifier(
          rules: [PurifyRule(pattern: '第2章', replacement: '终章')],
        ),
      ),
    );
    final second = await repo.getCatalog(
      bookId: 'book1',
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    expect(second.chapters[0].title, '第1章');
    expect(second.chapters[1].title, '终章(广告)');
  });
}
