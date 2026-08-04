import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:easy_read/features/search/domain/repositories/search_repository.dart';
import 'package:easy_read/features/search/domain/usecases/search_books.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';

class MockSearchRepository implements SearchRepository {
  @override
  Future<List<SearchResult>> search(String keyword, String sourceId) async {
    if (keyword.isEmpty) return [];
    return [
      SearchResult(
        bookId: '1',
        name: '测试书籍',
        author: '测试作者',
        sourceId: sourceId,
        sourceName: '测试源',
      ),
    ];
  }
}

class MockBookSourceRepository implements BookSourceRepository {
  @override
  Future<List<BookSource>> getAll() async => [];
  @override
  Future<BookSource?> getById(String id) async => null;
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
  late SearchBooks useCase;
  late MockSearchRepository mockSearchRepo;
  late MockBookSourceRepository mockSourceRepo;

  setUp(() {
    mockSearchRepo = MockSearchRepository();
    mockSourceRepo = MockBookSourceRepository();
    useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: mockSourceRepo);
  });

  test('should return empty list for empty keyword', () async {
    final results = await useCase.execute('', 'source1');
    expect(results, isEmpty);
  });

  test('should return search results for valid keyword', () async {
    final results = await useCase.execute('测试', 'source1');
    expect(results.length, 1);
    expect(results.first.name, '测试书籍');
  });
}
