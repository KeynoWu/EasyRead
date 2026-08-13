import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:easy_read/features/search/domain/repositories/search_repository.dart';
import 'package:easy_read/features/search/domain/usecases/search_books.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';

class MockSearchRepository implements SearchRepository {
  int? lastPage;

  @override
  Future<List<SearchResult>> searchWithSource(
    String keyword,
    BookSource source, {
    int? page,
    CancelToken? cancelToken,
    bool throwOnError = false,
  }) async {
    if (keyword.isEmpty) return [];
    lastPage = page;
    return [
      SearchResult(
        bookId: '${source.id}_1',
        name: '测试书籍',
        author: '测试作者',
        detailUrl: 'http://example.com/book/1',
        sourceId: source.id,
        sourceName: source.name,
      ),
    ];
  }

  @override
  Future<List<SearchResult>> exploreWithSource(
    BookSource source,
    String url, {
    int? page,
    CancelToken? cancelToken,
    bool throwOnError = false,
  }) async {
    return [];
  }
}

class MockBookSourceRepository implements BookSourceRepository {
  final List<BookSource> sources;

  MockBookSourceRepository(this.sources);

  @override
  Future<List<BookSource>> getAll() async => sources;
  @override
  Future<BookSource?> getById(String id) async {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
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
  Future<List<BookSource>> getEnabled() async =>
      sources.where((s) => s.enabled).toList();
}

void main() {
  late SearchBooks useCase;
  late MockSearchRepository mockSearchRepo;
  late MockBookSourceRepository mockSourceRepo;

  const testSource = BookSource(
    id: 'src1',
    name: '测试源',
    bookSourceUrl: 'http://example.com',
    rules: {'searchUrl': 'http://example.com/search?q={{key}}'},
  );

  setUp(() {
    mockSearchRepo = MockSearchRepository();
    mockSourceRepo = MockBookSourceRepository([testSource]);
    useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: mockSourceRepo);
  });

  test('should return empty list for empty keyword', () async {
    final results = await useCase.execute('', 'src1');
    expect(results, isEmpty);
  });

  test('should return empty list when source not found', () async {
    final results = await useCase.execute('测试', 'nonexistent');
    expect(results, isEmpty);
  });

  test('should search with source configuration', () async {
    final results = await useCase.execute('测试', 'src1');
    expect(results.length, 1);
    expect(results.first.name, '测试书籍');
    expect(results.first.sourceId, 'src1');
  });

  test('executeMultiSource should aggregate results', () async {
    final results = await useCase.executeMultiSource('测试');
    expect(results.length, 1);
    expect(results.first.name, '测试书籍');
    expect(results.first.sourceId, 'src1');
  });

  test('executeMultiSource should pass page to each source', () async {
    final results = await useCase.executeMultiSource('测试', page: 3);
    expect(results, isNotEmpty);
    expect(mockSearchRepo.lastPage, 3);
  });

  test('executeMultiSource should return empty when no sources', () async {
    final emptyRepo = MockBookSourceRepository([]);
    final emptyUseCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: emptyRepo);
    final results = await emptyUseCase.executeMultiSource('测试');
    expect(results, isEmpty);
  });

  test('executeMultiSource should skip sources marked non-searchable', () async {
    final hidden = testSource.copyWith(
      id: 'src2',
      rules: {'searchUrl': 'http://example.com/search?q={{key}}', 'searchable': false},
    );
    final repo = MockBookSourceRepository([testSource, hidden]);
    final useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: repo);

    final results = await useCase.executeMultiSource('测试');
    expect(results.length, 1);
    expect(results.first.sourceId, 'src1');
  });

  test('executeMultiSource should prefer higher weight source', () async {
    final low = testSource.copyWith(
      id: 'src1',
      rules: {'searchUrl': 'http://example.com/search?q={{key}}', 'weight': 1},
    );
    final high = testSource.copyWith(
      id: 'src2',
      rules: {'searchUrl': 'http://example.com/search?q={{key}}', 'weight': 10},
    );
    final repo = MockBookSourceRepository([low, high]);
    final useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: repo);

    final results = await useCase.executeMultiSource('测试');
    expect(results.first.sourceId, 'src2');
  });

  test('executeMultiSource should tolerate string weight values', () async {
    final source = testSource.copyWith(
      id: 'src1',
      rules: {'searchUrl': 'http://example.com/search?q={{key}}', 'weight': '10'},
    );
    final repo = MockBookSourceRepository([source]);
    final useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: repo);

    final results = await useCase.executeMultiSource('测试');
    expect(results, isNotEmpty);
    expect(results.first.sourceId, 'src1');
  });

  test('executeMultiSource should skip string boolean non-searchable source', () async {
    final hidden = testSource.copyWith(
      id: 'src2',
      rules: {'searchUrl': 'http://example.com/search?q={{key}}', 'searchable': 'false'},
    );
    final repo = MockBookSourceRepository([testSource, hidden]);
    final useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: repo);

    final results = await useCase.executeMultiSource('测试');
    expect(results.length, 1);
    expect(results.first.sourceId, 'src1');
  });



  group('searchWithProgress 流式搜索', () {
    const secondSource = BookSource(
      id: 'src2',
      name: '测试源2',
      bookSourceUrl: 'http://example2.com',
      rules: {'searchUrl': 'http://example2.com/search?q={{key}}'},
    );

    test('每源完成产出累积结果，最终去重并追加替代源', () async {
      mockSourceRepo = MockBookSourceRepository([testSource, secondSource]);
      useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: mockSourceRepo);

      final progress = <SearchProgress>[];
      await for (final p in useCase.searchWithProgress('测试')) {
        progress.add(p);
      }

      expect(progress, isNotEmpty);
      final last = progress.last;
      expect(last.finished, isTrue);
      expect(last.total, 2);
      expect(last.completed, 2);
      // 两个源返回同名书 → 去重为 1 条，后到的成为替代源
      expect(last.results.length, 1);
      expect(last.results.first.alternatives.length, 1);
      expect(last.results.first.alternatives.first.sourceId, anyOf('src1', 'src2'));
    });

    test('completed 单调递增，结果不倒退', () async {
      mockSourceRepo = MockBookSourceRepository([testSource, secondSource]);
      useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: mockSourceRepo);

      final progress = <SearchProgress>[];
      await for (final p in useCase.searchWithProgress('测试')) {
        progress.add(p);
      }

      final completedSeq = progress.map((p) => p.completed).toList();
      for (var i = 1; i < completedSeq.length; i++) {
        expect(completedSeq[i] >= completedSeq[i - 1], isTrue,
            reason: 'completed 必须单调不减: $completedSeq');
      }
      expect(completedSeq.last, 2);
    });

    test('finished:true 事件只发出一次（防 UI 重复合并）', () async {
      mockSourceRepo = MockBookSourceRepository([testSource, secondSource]);
      useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: mockSourceRepo);

      final progress = <SearchProgress>[];
      await for (final p in useCase.searchWithProgress('测试')) {
        progress.add(p);
      }

      expect(progress.where((p) => p.finished).length, 1);
      expect(progress.last.finished, isTrue);
    });

    test('mergeResults 对重复替代源去重', () {
      SearchResult book(SearchResult existing, SourceOption alt) => SearchResult(
        bookId: existing.bookId,
        name: existing.name,
        author: existing.author,
        sourceId: existing.sourceId,
        sourceName: existing.sourceName,
        alternatives: [...existing.alternatives, alt],
      );

      const primary = SearchResult(
        bookId: 'a_1',
        name: '同一本书',
        author: '作者',
        sourceId: 'srcA',
        sourceName: 'A',
      );
      const alt1 = SourceOption(
        bookId: 'b_1',
        sourceId: 'srcB',
        sourceName: 'B',
      );
      const alt2 = SourceOption(
        bookId: 'c_1',
        sourceId: 'srcC',
        sourceName: 'C',
      );

      final current = [book(primary, alt1)];
      // 模拟重复合并：incoming 与 current 完全相同的批次再合并一次
      final mergedOnce = SearchBooks.mergeResults(current, current);
      expect(mergedOnce.single.alternatives.length, 1);
      // 新批次带来新替代源时正常追加
      final mergedNew = SearchBooks.mergeResults(
        mergedOnce,
        [book(primary, alt2)],
      );
      expect(mergedNew.single.alternatives.length, 2);
      expect(
        mergedNew.single.alternatives.map((a) => a.sourceId).toSet(),
        {'srcB', 'srcC'},
      );
    });

    test('无可用书源立即完成（total=0）', () async {
      mockSourceRepo = MockBookSourceRepository([]);
      useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: mockSourceRepo);

      final progress = <SearchProgress>[];
      await for (final p in useCase.searchWithProgress('测试')) {
        progress.add(p);
      }

      expect(progress.length, 1);
      expect(progress.single.finished, isTrue);
      expect(progress.single.total, 0);
      expect(progress.single.results, isEmpty);
    });

    test('空关键词立即完成', () async {
      final progress = <SearchProgress>[];
      await for (final p in useCase.searchWithProgress('  ')) {
        progress.add(p);
      }
      expect(progress.single.finished, isTrue);
    });

    test('取消后不发出 finished:true 的残缺进度', () async {
      final token = CancelToken()..cancel();
      final progress = <SearchProgress>[];
      await for (final p
          in useCase.searchWithProgress('测试', cancelToken: token)) {
        progress.add(p);
      }
      expect(progress, isEmpty);
    });

    test('searchWithProgress 透传 page', () async {
      await for (final _ in useCase.searchWithProgress('测试', page: 2)) {
        // 消费流即可
      }
      expect(mockSearchRepo.lastPage, 2);
    });
  });

}
