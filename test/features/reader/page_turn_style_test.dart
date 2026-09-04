import 'dart:io';

import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/settings/domain/entities/chinese_conversion.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeSourceRepo implements BookSourceRepository {
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

/// 注入固定章节的仓库替身：绕过真实网络/解析链路，
/// 让 loadChapter + setViewport 能产出真实分页结果。
class _FakeRepo extends ReaderRepositoryImpl {
  _FakeRepo() : super(sourceRepo: _FakeSourceRepo());

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
    ChineseConversionMode chineseMode = ChineseConversionMode.original,
  }) async {
    // 足够多的段落，保证 400x600 视口下能分成多页
    const paragraph = '这是一段用于分页测试的正文内容，包含足够多的文字以保证分页引擎能把章节切分成多页。';
    return Chapter(
      id: '$bookId#$chapterIndex',
      bookId: bookId,
      title: '第${chapterIndex + 1}章',
      content: List.filled(60, paragraph).join('\n\n'),
      index: chapterIndex,
      sourceId: sourceId,
    );
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => null;

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
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init(
      Directory.systemTemp.createTempSync('page_turn_style_test').path,
    );
  });

  setUp(() async {
    final box = await Hive.openBox<dynamic>('reader_settings');
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  ProviderContainer makeContainer() {
    return ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(_FakeRepo()),
    ]);
  }

  test('三种翻页动画样式持久化并可跨会话恢复', () async {
    for (final style in PageTurnStyle.values) {
      final container1 = makeContainer();
      addTearDown(container1.dispose);
      final notifier1 = container1.read(readerProvider.notifier);
      await notifier1.loadPersistedSettings();
      notifier1.switchPageTurnStyle(style);
      // 等待 unawaited 的 Hive 写入完成
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final container2 = makeContainer();
      addTearDown(container2.dispose);
      await container2.read(readerProvider.notifier).loadPersistedSettings();
      expect(container2.read(readerProvider).pageTurnStyle, style);
    }
  });

  test('切换翻页动画不重置当前页', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
    notifier.setViewport(400, 600);
    final pageCount = container.read(readerProvider).pages.length;
    expect(pageCount, greaterThan(1));

    notifier.nextPage();
    final before = container.read(readerProvider).currentPage;
    expect(before, 1);

    notifier.switchPageTurnStyle(PageTurnStyle.cover);
    final state = container.read(readerProvider);
    expect(state.pageTurnStyle, PageTurnStyle.cover);
    // 切样式只换动画，进度维度不变
    expect(state.currentPage, before);
    // 等待进度防抖定时器落盘，避免测试结束时残留 Timer
    await Future<void>.delayed(const Duration(milliseconds: 600));
  });

  test('switchPageTurnStyle 立即更新状态', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    expect(container.read(readerProvider).pageTurnStyle, PageTurnStyle.flip);

    notifier.switchPageTurnStyle(PageTurnStyle.slide);
    expect(container.read(readerProvider).pageTurnStyle, PageTurnStyle.slide);

    notifier.switchPageTurnStyle(PageTurnStyle.cover);
    expect(container.read(readerProvider).pageTurnStyle, PageTurnStyle.cover);
    // 等待 unawaited 的 Hive 写入完成
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('缺失或非法持久化数据回退默认翻页动画', () async {
    // 空盒：无任何持久化数据
    final container = makeContainer();
    addTearDown(container.dispose);
    await container.read(readerProvider.notifier).loadPersistedSettings();
    expect(container.read(readerProvider).pageTurnStyle, PageTurnStyle.flip);

    // 旧数据：只有旧字段，没有 pageTurnStyle
    final box = await Hive.openBox<dynamic>('reader_settings');
    await box.put('readingMode', ReadingMode.scroll.index);
    await box.put('fontSize', 20.0);
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings();
    expect(container2.read(readerProvider).pageTurnStyle, PageTurnStyle.flip);

    // 非法 index
    await box.put('pageTurnStyle', 99);
    final container3 = makeContainer();
    addTearDown(container3.dispose);
    await container3.read(readerProvider.notifier).loadPersistedSettings();
    expect(container3.read(readerProvider).pageTurnStyle, PageTurnStyle.flip);

    // 未知 name
    await box.put('pageTurnStyle', 'bogus');
    final container4 = makeContainer();
    addTearDown(container4.dispose);
    await container4.read(readerProvider.notifier).loadPersistedSettings();
    expect(container4.read(readerProvider).pageTurnStyle, PageTurnStyle.flip);
  });

  test('以名称字符串存储的 pageTurnStyle 可兼容读取', () async {
    final box = await Hive.openBox<dynamic>('reader_settings');
    await box.put('pageTurnStyle', 'cover');

    final container = makeContainer();
    addTearDown(container.dispose);
    await container.read(readerProvider.notifier).loadPersistedSettings();
    expect(container.read(readerProvider).pageTurnStyle, PageTurnStyle.cover);
  });
}
