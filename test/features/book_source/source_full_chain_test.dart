import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/features/book_source/data/services/book_source_test_store.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source_test_record.dart';
import 'package:easy_read/features/book_source/domain/usecases/batch_test_book_sources.dart';
import 'package:easy_read/features/book_source/domain/usecases/test_book_source.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart' show ChapterLoadException, ChapterErrorKind;
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:easy_read/features/settings/domain/entities/chinese_conversion.dart';
import 'package:easy_read/features/reader/domain/repositories/reader_repository.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';

/// 可控测试器：搜索恒成功并返回一个带详情链接的样例
class _SearchOkTester extends TestBookSource {
  String? lastKeyword;

  _SearchOkTester({super.readerRepo});

  @override
  Future<BookSourceTestResult> testSearch(
    BookSource source,
    String keyword, {
    dio.CancelToken? cancelToken,
  }) async {
    lastKeyword = keyword;
    return BookSourceTestResult(
      success: true,
      message: 'ok',
      resultCount: 1,
      samples: [
        SearchResult(
          bookId: 'b1',
          name: '样例书',
          detailUrl: 'https://s.example.com/book/1',
          sourceId: source.id,
          sourceName: source.name,
        ),
      ],
    );
  }
}

/// 目录/正文行为可编程的假阅读仓库
class _ChainReaderRepo implements ReaderRepository {
  final List<ChapterItem> Function() catalogFactory;
  final String Function() contentFactory;
  final bool catalogThrows;

  _ChainReaderRepo({
    List<ChapterItem> Function()? catalogFactory,
    String Function()? contentFactory,
    this.catalogThrows = false,
  })  : catalogFactory = catalogFactory ?? (() => []),
        contentFactory = contentFactory ?? (() => '正文内容');

  @override
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    Map<String, String> variables = const {},
  }) async {
    if (catalogThrows) {
      throw const ChapterLoadException('详情页加载失败', kind: ChapterErrorKind.sourceError);
    }
    return ChapterCatalog(
      bookId: bookId,
      fetchedAt: DateTime.now(),
      chapters: [
        const ChapterItem(title: '第一章', url: 'https://s.example.com/ch/1', index: 0),
        const ChapterItem(title: '第二章', url: 'https://s.example.com/ch/2', index: 1),
      ],
    );
  }

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
    ChineseConversionMode chineseMode = ChineseConversionMode.original,
  }) async {
    return Chapter(
      id: 'ch_$chapterIndex',
      bookId: bookId,
      title: '第一章',
      content: contentFactory(),
      index: chapterIndex,
      sourceId: sourceId,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

BookSource _source() => const BookSource(
      id: 'src1',
      name: '测试源',
      bookSourceUrl: 'https://s.example.com',
      enabled: true,
      rules: {
        'searchUrl': 'https://s.example.com/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3',
        'bookDetailUrl': 'a@href',
        'chapterList': 'ul > li',
        'chapterName': 'a',
        'chapterUrl': 'a@href',
      },
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('full_chain');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  test('§三-11 全链路可用：搜索+目录+正文全过 → usable 且无分组', () async {
    final store = BookSourceTestStore();
    final batch = BatchTestBookSources(
      tester: _SearchOkTester(
        readerRepo: _ChainReaderRepo(
          contentFactory: () => '正文内容较长' * 10,
        ),
      ),
      store: store,
    );

    final summary = await batch.run(sources: [_source()]);
    expect(summary.usable, 1);
    final record = await store.get('src1');
    expect(record!.usable, isTrue);
    expect(record.groups, isEmpty);
  });

  test('§三-11 目录失效：目录抛错 → 分组「目录失效」且不可用', () async {
    final store = BookSourceTestStore();
    final batch = BatchTestBookSources(
      tester: _SearchOkTester(readerRepo: _ChainReaderRepo(catalogThrows: true)),
      store: store,
    );

    await batch.run(sources: [_source()]);
    final record = await store.get('src1');
    expect(record!.usable, isFalse);
    expect(record.groups, ['目录失效']);
    expect(record.error, '目录失效');
  });

  test('§三-11 正文失效：目录可用但正文空 → 分组「正文失效」', () async {
    final store = BookSourceTestStore();
    final batch = BatchTestBookSources(
      tester: _SearchOkTester(
        readerRepo: _ChainReaderRepo(contentFactory: () => '   '),
      ),
      store: store,
    );

    await batch.run(sources: [_source()]);
    final record = await store.get('src1');
    expect(record!.usable, isFalse);
    expect(record.groups, ['正文失效']);
  });

  test('§三-11 groups 持久化 round trip', () async {
    final store = BookSourceTestStore();
    final r = BookSourceTestRecord(
      usable: false,
      responseTimeMs: 100,
      testedAt: DateTime(2026, 1, 1),
      groups: ['目录失效', '正文失效'],
      error: '目录失效、正文失效',
    );
    await store.save('src1', r);
    final loaded = await store.get('src1');
    expect(loaded!.groups, ['目录失效', '正文失效']);
    expect(loaded.error, '目录失效、正文失效');
  });

  test('§三-11 源级 checkKeyWord 覆盖批测统一关键词', () async {
    final tester = _SearchOkTester(readerRepo: _ChainReaderRepo());
    final batch = BatchTestBookSources(
      tester: tester,
      store: BookSourceTestStore(),
    );
    const source = BookSource(
      id: 'kw1',
      name: '带检测词源',
      bookSourceUrl: 'https://kw.example.com',
      enabled: true,
      rules: {
        'searchUrl': 'https://kw.example.com/search?q={{key}}',
        'bookList': 'div.item',
        'bookName': 'h3',
        'checkKeyWord': '我的世界',
      },
    );
    await batch.run(sources: [source]);
    expect(tester.lastKeyword, '我的世界', reason: 'Legado getCheckKeyword：源级检测词优先');
  });
}
