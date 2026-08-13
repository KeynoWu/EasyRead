import 'package:easy_read/features/reader/domain/entities/book_detail.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/domain/repositories/reader_repository.dart';
import 'package:easy_read/features/reader/domain/usecases/auto_switch_source.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假仓库：按 sourceId 配置目录结果（成功目录或抛错），并记录尝试顺序
class _FakeReaderRepository implements ReaderRepository {
  final Map<String, ChapterCatalog> catalogs = {};
  final Map<String, Exception> errors = {};
  final List<String> attempted = [];

  @override
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    Map<String, String> variables = const {},
  }) async {
    attempted.add(sourceId);
    final catalog = catalogs[sourceId];
    if (catalog != null) return catalog;
    final error = errors[sourceId];
    if (error != null) throw error;
    throw Exception('未配置 $sourceId 的目录结果');
  }

  @override
  Future<BookDetail> getBookDetail({
    required String bookId,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    throw UnimplementedError();
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
  const bookId = 'book-1';
  const currentSourceId = 'src-a';

  SourceOption alt(String sourceId, String name, {String? detailUrl}) {
    return SourceOption(
      bookId: bookId,
      sourceId: sourceId,
      sourceName: name,
      detailUrl: detailUrl ?? 'https://$sourceId.example.com/book',
    );
  }

  ChapterCatalog makeCatalog(String sourceId) {
    return ChapterCatalog(
      bookId: bookId,
      fetchedAt: DateTime(2026, 1, 1),
      chapters: [
        ChapterItem(
          title: '第一章',
          url: 'https://$sourceId.example.com/chapter/1',
          index: 0,
        ),
      ],
    );
  }

  test('首个可用书源成功时返回该源信息与目录', () async {
    final repo = _FakeReaderRepository()
      ..errors['src-b'] = Exception('目录加载失败')
      ..catalogs['src-c'] = makeCatalog('src-c');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      currentDetailUrl: 'https://src-a.example.com/book',
      alternatives: [
        alt(currentSourceId, '源A'), // 当前源：应被跳过
        alt('src-b', '源B'),
        alt('src-c', '源C'),
      ],
    );

    expect(result, isNotNull);
    expect(result!.sourceId, 'src-c');
    expect(result.sourceName, '源C');
    expect(result.detailUrl, 'https://src-c.example.com/book');
    expect(result.catalog.chapters.single.title, '第一章');
    // 当前源未被尝试；失败的源尝试后继续
    expect(repo.attempted, ['src-b', 'src-c']);
  });

  test('全部替代源失败时返回 null', () async {
    final repo = _FakeReaderRepository()
      ..errors['src-b'] = Exception('目录加载失败')
      ..errors['src-c'] = Exception('目录加载失败');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [
        alt(currentSourceId, '源A'),
        alt('src-b', '源B'),
        alt('src-c', '源C'),
        alt('src-d', '源D', detailUrl: ''), // 无详情页：跳过不尝试
      ],
    );

    expect(result, isNull);
    expect(repo.attempted, ['src-b', 'src-c']);
  });

  test('跳过当前书源（即使其目录可用也不尝试）', () async {
    final repo = _FakeReaderRepository()
      ..catalogs[currentSourceId] = makeCatalog(currentSourceId);
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [alt(currentSourceId, '源A')],
    );

    expect(result, isNull);
    expect(repo.attempted, isEmpty);
  });

  test('单源失败后立即尝试下一个源', () async {
    final repo = _FakeReaderRepository()
      ..errors['src-b'] = Exception('目录加载失败')
      ..catalogs['src-c'] = makeCatalog('src-c');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [
        alt('src-b', '源B'),
        alt('src-c', '源C'),
      ],
    );

    expect(result, isNotNull);
    expect(result!.sourceId, 'src-c');
    expect(repo.attempted, ['src-b', 'src-c']);
  });

  test('空目录视为不可用，继续尝试下一个源', () async {
    final repo = _FakeReaderRepository()
      ..catalogs['src-b'] = ChapterCatalog(
        bookId: bookId,
        fetchedAt: DateTime(2026, 1, 1),
        chapters: const [],
      )
      ..catalogs['src-c'] = makeCatalog('src-c');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [
        alt('src-b', '源B'),
        alt('src-c', '源C'),
      ],
    );

    expect(result, isNotNull);
    expect(result!.sourceId, 'src-c');
    expect(repo.attempted, ['src-b', 'src-c']);
  });
}
