import 'dart:io';

import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:easy_read/features/reader/presentation/widgets/page_view_widget.dart';
import 'package:flutter/material.dart';
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

/// 注入固定章节的仓库替身：段落文本互不相同，便于断言"每屏两页"的左右栏内容。
/// 绕过真实网络/解析链路，让 loadChapter + setViewport 能产出真实分页结果。
class _FakeRepo extends ReaderRepositoryImpl {
  final int paragraphCount;
  _FakeRepo({this.paragraphCount = 60}) : super(sourceRepo: _FakeSourceRepo());

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return Chapter(
      id: '$bookId#$chapterIndex',
      bookId: bookId,
      title: '第${chapterIndex + 1}章',
      // 用 <p> 包裹每段：与真实书源一致，解析器按段产出独立节点，
      // 便于断言"每屏两页"时左右栏各自的段落文本
      content: List.generate(
        paragraphCount,
        (i) =>
            '<p>这是第${i + 1}段用于分页测试的正文内容，包含足够多的文字以保证分页引擎能把章节切分成多页。</p>',
      ).join(),
      index: chapterIndex,
      sourceId: sourceId,
    );
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> saveProgress(ReadingProgress progress) async {}

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
      Directory.systemTemp.createTempSync('landscape_dual_page_test').path,
    );
  });

  setUp(() async {
    final box = await Hive.openBox<dynamic>('reader_settings');
    await box.clear();
  });

  tearDownAll(() async {
    // 不在 tearDownAll 执行 Hive.deleteFromDisk：widget 测试（FakeAsync 区域）
    // 内发起的 Hive 写事务无法在 tearDownAll 的真实异步窗口完成，会导致
    // deleteFromDisk 永久挂起；临时目录由系统清理，不影响其他测试文件。
  });

  ProviderContainer makeContainer({int paragraphCount = 60}) {
    return ProviderContainer(overrides: [
      readerRepositoryProvider
          .overrideWithValue(_FakeRepo(paragraphCount: paragraphCount)),
    ]);
  }

  group('横屏双栏：分页与翻页语义（provider 层）', () {
    test('横屏分页宽度减半：双栏分页与同尺寸正方形视口分页完全一致', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      notifier.setViewport(800, 400); // 横屏：分页宽度 = 800 / 2 = 400
      final dual = container.read(readerProvider).pages;
      expect(dual.length, greaterThan(1));

      // 对照：400x400 非双栏，分页尺寸恰好与双栏的减半宽度 + 原高度一致，
      // 两者分页结果必须逐页一致，证明横屏时确实按半屏宽度分页
      notifier.setViewport(400, 400);
      final square = container.read(readerProvider).pages;
      expect(square.length, dual.length);
      for (var i = 0; i < dual.length; i++) {
        expect(
          square[i].nodes.map((n) => n.text).join('|'),
          dual[i].nodes.map((n) => n.text).join('|'),
        );
      }
    });

    test('横屏双栏：翻页步长为 2、当前页恒为左栏偶数页、末屏不再前进', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      notifier.setViewport(800, 400);
      var state = container.read(readerProvider);
      expect(state.currentPage, 0);

      notifier.nextPage();
      state = container.read(readerProvider);
      expect(state.currentPage, 2);

      notifier.nextPage();
      state = container.read(readerProvider);
      expect(state.currentPage, 4);

      notifier.prevPage();
      state = container.read(readerProvider);
      expect(state.currentPage, 2);

      // 末屏（最后一个左栏页）：nextPage 不再前进
      final lastLeft = state.pages.length.isEven
          ? state.pages.length - 2
          : state.pages.length - 1;
      notifier.jumpToPage(lastLeft);
      state = container.read(readerProvider);
      expect(state.currentPage, lastLeft);
      notifier.nextPage();
      expect(container.read(readerProvider).currentPage, lastLeft);

      // 奇数目标页对齐到所在屏幕的左栏（目标页显示在右栏），当前页仍是左栏
      expect(state.pages.length, greaterThan(3));
      notifier.jumpToPage(3);
      expect(container.read(readerProvider).currentPage, 2);
      notifier.jumpToPage(1);
      expect(container.read(readerProvider).currentPage, 0);

      // 等待进度防抖定时器落盘，避免测试结束时残留 Timer
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });

    test('竖屏行为不变：步长 1、jumpToPage 精确跳转、越界忽略', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      notifier.setViewport(400, 600);
      final pages = container.read(readerProvider).pages;
      expect(pages.length, greaterThan(5));

      notifier.nextPage();
      expect(container.read(readerProvider).currentPage, 1);
      notifier.nextPage();
      expect(container.read(readerProvider).currentPage, 2);
      notifier.prevPage();
      expect(container.read(readerProvider).currentPage, 1);
      notifier.jumpToPage(5);
      expect(container.read(readerProvider).currentPage, 5);
      notifier.jumpToPage(pages.length); // 越界被忽略
      expect(container.read(readerProvider).currentPage, 5);

      await Future<void>.delayed(const Duration(milliseconds: 600));
    });

    test('横屏旋转恢复：竖屏第 5 页旋转横屏后对齐到页 5 所在屏幕的左栏', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      notifier.setViewport(400, 600);
      notifier.jumpToPage(5);
      expect(container.read(readerProvider).currentPage, 5);

      notifier.setViewport(800, 400); // 旋转横屏
      // 页 5 所在屏幕为 [4,5]，左栏 = 4；nextPage 整屏前进到 [6,7]
      expect(container.read(readerProvider).currentPage, 4);
      notifier.nextPage();
      expect(container.read(readerProvider).currentPage, 6);

      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
  });

  group('横屏双栏：渲染（widget 层）', () {
    Future<ProviderContainer> pumpReader(
      WidgetTester tester, {
      required int paragraphCount,
      required Size size,
    }) async {
      final container = makeContainer(paragraphCount: paragraphCount);
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: size.width,
                height: size.height,
                child: const ReaderPageView(),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // postFrame 上报视口（setViewport）
      await tester.pump(); // 分页完成后的重建
      return container;
    }

    testWidgets('横屏双栏：每屏并排渲染两页，翻屏后显示下一对页', (tester) async {
      final container = await pumpReader(
        tester,
        paragraphCount: 60,
        size: const Size(800, 400),
      );
      final pages = container.read(readerProvider).pages;
      expect(pages.length, greaterThan(2));
      expect(find.text('本章完'), findsNothing);

      // 首屏：左栏 = 页 0 首段，右栏 = 页 1 首段，两者同时可见
      final page0First = pages[0].nodes.first.text;
      final page1First = pages[1].nodes.first.text;
      expect(page0First, isNot(page1First));
      expect(find.text(page0First), findsOneWidget);
      expect(find.text(page1First), findsOneWidget);

      // 拖一整屏（拖 3/4 屏宽确保越过半页阈值）：显示页 2、页 3
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text(pages[2].nodes.first.text), findsOneWidget);
      expect(find.text(pages[3].nodes.first.text), findsOneWidget);
      expect(container.read(readerProvider).currentPage, 2);

      // 等待进度防抖定时器落盘，避免测试结束时残留 Timer
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('横屏双栏末屏：总页数为奇数时右栏显示本章完', (tester) async {
      final container = await pumpReader(
        tester,
        paragraphCount: 9,
        size: const Size(800, 400),
      );
      final pages = container.read(readerProvider).pages;
      // 9 段 → 页面区域高度（约 372）下每页 3 段 → 3+3+3 = 3 页（奇数 → 末屏右栏占位）
      expect(pages.length, 3);
      expect(find.text('本章完'), findsNothing); // 首屏无占位

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      // 末屏：左栏显示最后一页，右栏显示"本章完"
      expect(find.text('本章完'), findsOneWidget);
      expect(find.text(pages[2].nodes.first.text), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('竖屏保持单栏：首屏只有一页内容、无本章完占位', (tester) async {
      final container = await pumpReader(
        tester,
        paragraphCount: 60,
        size: const Size(400, 600),
      );
      final pages = container.read(readerProvider).pages;
      expect(pages.length, greaterThan(1));
      expect(find.text(pages[0].nodes.first.text), findsOneWidget);
      // 第二页内容不在首屏（单栏）
      expect(find.text(pages[1].nodes.first.text), findsNothing);
      expect(find.text('本章完'), findsNothing);
    });

    // 放在组末尾：switchPageTurnStyle 会向 reader_settings 盒写入持久化数据，
    // 该写事务在 testWidgets 的 FakeAsync 区域内无法完成落盘；若其后还有用例，
    // 其 setUp 的 box.clear() 会对非空盒发起真实文件 I/O 而永久挂起。
    // 放末尾可避免后续用例清理，且不触发 tearDownAll 的 Hive 磁盘操作。
    testWidgets('双栏下覆盖翻页动画可正常整屏翻动', (tester) async {
      final container = await pumpReader(
        tester,
        paragraphCount: 60,
        size: const Size(800, 400),
      );
      container
          .read(readerProvider.notifier)
          .switchPageTurnStyle(PageTurnStyle.cover);
      await tester.pump();

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      // 翻屏成功且状态同步：当前页 = 屏幕 1 的左栏页
      expect(container.read(readerProvider).currentPage, 2);

      // 等待进度防抖定时器落盘，避免测试结束时残留 Timer
      await tester.pump(const Duration(milliseconds: 600));
      // 真实异步窗口：让 switchPageTurnStyle 未 await 的 Hive 持久化写入
      // 有机会完成落盘，避免残留写事务
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    });
  });
}
