import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:easy_read/features/search/domain/repositories/search_repository.dart';
import 'package:easy_read/features/search/domain/usecases/search_books.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';

class MockSearchRepository implements SearchRepository {
  @override
  Future<List<SearchResult>> searchWithSource(String keyword, BookSource source) async {
    if (keyword.isEmpty) return [];
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
}
