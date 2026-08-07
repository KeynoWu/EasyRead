import 'dart:io';
import 'package:easy_read/features/bookshelf/data/services/auto_refresh_service.dart';
import 'package:easy_read/features/bookshelf/data/services/book_detail_service.dart'
    show BookDetailService;
import 'package:easy_read/features/bookshelf/domain/entities/book.dart';
import 'package:easy_read/features/bookshelf/domain/repositories/bookshelf_repository.dart';
import 'package:easy_read/features/reader/domain/entities/book_detail.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/domain/repositories/reader_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _MemoryBookshelf implements BookshelfRepository {
  final List<Book> books;
  final List<Book> saved = [];

  _MemoryBookshelf(this.books);

  @override
  Future<List<Book>> getAll() async => books;
  @override
  Future<Book?> getById(String id) async {
    for (final book in books) {
      if (book.id == id) return book;
    }
    return null;
  }
  @override
  Future<void> save(Book book) async => saved.add(book);
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> deleteAll(List<String> ids) async {}
  @override
  Future<void> updateProgress(String id, double progress) async {}
}

class _FakeReader implements ReaderRepository {
  final BookDetail detail;

  _FakeReader(this.detail);

  @override
  Future<BookDetail> getBookDetail({
    required String bookId,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return detail;
  }

  @override
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return ChapterCatalog(bookId: bookId, fetchedAt: DateTime.now());
  }

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {}
  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => null;
  @override
  Future<void> clearBookCache(String bookId) async {}
  @override
  Future<void> preloadChapters({
    required String bookId,
    required int startIndex,
    required int count,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {}
}

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_auto_refresh').path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('自动更新器拉取详情并保存新书名/最新章节', () async {
    final books = [
      Book(
        id: 'b1',
        name: '旧书名',
        sourceId: 'src1',
        lastReadAt: DateTime(2026, 1, 1),
      ),
    ];
    final bookshelf = _MemoryBookshelf(books);
    final detailService = BookDetailService();
    await detailService.save('b1', detailUrl: 'https://example.com/book/1');

    final updater = BookshelfAutoUpdater(
      readerRepo: _FakeReader(const BookDetail(
        bookId: 'b1',
        name: '新书名',
        lastChapter: '第2章',
      )),
      bookshelfRepo: bookshelf,
      detailService: detailService,
    );

    final updated = await updater.updateAll();
    expect(updated, 1);
    expect(bookshelf.saved.single.name, '新书名');
    expect(bookshelf.saved.single.lastChapter, '第2章');
  });

  test('缺少详情 URL 的书籍跳过', () async {
    final books = [
      Book(
        id: 'b1',
        name: '旧书名',
        sourceId: 'src1',
        lastReadAt: DateTime(2026, 1, 1),
      ),
    ];
    final bookshelf = _MemoryBookshelf(books);
    final detailService = BookDetailService();

    final updater = BookshelfAutoUpdater(
      readerRepo: _FakeReader(const BookDetail(bookId: 'b1', name: '新书名')),
      bookshelfRepo: bookshelf,
      detailService: detailService,
    );

    final updated = await updater.updateAll();
    expect(updated, 0);
    expect(bookshelf.saved, isEmpty);
  });

  test('自动更新设置保存与读取', () async {
    expect(await AutoRefreshSettings.load(), 0);
    await AutoRefreshSettings.save(6);
    expect(await AutoRefreshSettings.load(), 6);
  });
}
