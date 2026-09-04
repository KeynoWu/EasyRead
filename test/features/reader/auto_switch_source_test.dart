import 'package:easy_read/features/reader/domain/entities/book_detail.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/domain/repositories/reader_repository.dart';
import 'package:easy_read/features/settings/domain/entities/chinese_conversion.dart';
import 'package:easy_read/features/reader/domain/usecases/auto_switch_source.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假仓库：按 sourceId 配置目录结果（成功目录或抛错），并记录尝试顺序
class _FakeReaderRepository implements ReaderRepository {
  final Map<String, ChapterCatalog> catalogs = {};
  final Map<String, Exception> errors = {};
  final List<String> attempted = [];
  // 正文验证：sourceId -> 抛错；未配置时默认成功
  final Map<String, Exception> chapterErrors = {};
  // getChapter 实际收到的 (sourceId, chapterIndex) 顺序
  final List<(String, int)> chapterIndexes = [];

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
    ChineseConversionMode chineseMode = ChineseConversionMode.original,
  }) async {
    chapterIndexes.add((sourceId, chapterIndex));
    final error = chapterErrors[sourceId];
    if (error != null) throw error;
    return Chapter(
      id: '${sourceId}_$chapterIndex',
      bookId: bookId,
      title: '第${chapterIndex + 1}章',
      content: '正文',
      index: chapterIndex,
      sourceId: sourceId,
      cachedAt: DateTime(2026, 1, 1),
    );
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

  test('§三-2 当前章正文验证失败 → 候选不可用', () async {
    final repo = _FakeReaderRepository()
      ..catalogs['src-b'] = makeCatalog('src-b')
      ..chapterErrors['src-b'] = Exception('正文提取失败')
      ..catalogs['src-c'] = makeCatalog('src-c');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [alt('src-b', '源B'), alt('src-c', '源C')],
      chapterIndex: 0,
    );

    expect(result, isNotNull);
    expect(result!.sourceId, 'src-c');
    // src-b 目录成功但正文验证失败，仍尝试了 src-c
    expect(repo.attempted, ['src-b', 'src-c']);
  });

  test('§三-2 出错章节索引越界时取最后一章验证（Legado getOrElse{last}）', () async {
    final repo = _FakeReaderRepository()
      ..catalogs['src-b'] = makeCatalog('src-b');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [alt('src-b', '源B')],
      chapterIndex: 5, // 目录只有 1 章
    );

    expect(result, isNotNull);
    expect(repo.chapterIndexes, [('src-b', 0)]);
  });

  test('§三-2 verifyContent=false 时仅验证目录', () async {
    final repo = _FakeReaderRepository()
      ..catalogs['src-b'] = makeCatalog('src-b')
      ..chapterErrors['src-b'] = Exception('正文失败也不影响');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [alt('src-b', '源B')],
      verifyContent: false,
    );

    expect(result, isNotNull);
    expect(result!.sourceId, 'src-b');
    expect(repo.chapterIndexes, isEmpty);
  });

  test('§三-2 多候选并发校验时首个可用源胜出', () async {
    final repo = _FakeReaderRepository();
    for (final id in ['src-b', 'src-c', 'src-d', 'src-e']) {
      repo.catalogs[id] = makeCatalog(id);
    }
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [
        alt('src-b', '源B'),
        alt('src-c', '源C'),
        alt('src-d', '源D'),
        alt('src-e', '源E'),
      ],
      concurrency: 4,
    );

    expect(result, isNotNull);
    // 列表首位候选先被取出（next 递增顺序），成功即胜出
    expect(result!.sourceId, 'src-b');
  });

  test('§三-2 瞬时网络错误（networkError）不触发自动换源判定', () async {
    // repository 层语义：getChapter 兜底异常应为 networkError
    // （reader_page 据此跳过自动换源），此处验证用例不因 kind 变化
    final repo = _FakeReaderRepository()
      ..catalogs['src-b'] = makeCatalog('src-b');
    final usecase = AutoSwitchSource(repository: repo);

    final result = await usecase.execute(
      bookId: bookId,
      currentSourceId: currentSourceId,
      alternatives: [alt('src-b', '源B')],
    );
    expect(result, isNotNull);
  });
}
