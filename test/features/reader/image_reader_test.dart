import 'dart:io';

import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/core/parser/node_tree.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:easy_read/features/reader/presentation/widgets/image_reader_widget.dart';
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

/// 注入固定章节内容的仓库替身：绕过真实网络/净化链路，
/// 让 loadChapter 直接产出可断言的 nodes / isImageChapter / pages。
class _FakeRepo extends ReaderRepositoryImpl {
  final String chapterHtml;
  final ReadingProgress? initialProgress;
  /// 最近一次落盘的进度（saveProgress 调用记录，验证进度保存复用）
  ReadingProgress? lastSaved;

  _FakeRepo({
    required this.chapterHtml,
    this.initialProgress,
  }) : super(sourceRepo: _FakeSourceRepo());

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
      content: chapterHtml,
      index: chapterIndex,
      sourceId: sourceId,
    );
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => initialProgress;

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    lastSaved = progress;
  }

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

/// 生成 N 张图片的章节 HTML（纯图，无文字节点）
String _imageChapterHtml(int imageCount) => List.generate(
      imageCount,
      (i) => '<img src="https://img.example.com/${i + 1}.jpg">',
    ).join();

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init(
      Directory.systemTemp.createTempSync('image_reader_test').path,
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

  ProviderContainer makeContainer({required String html, ReadingProgress? progress}) {
    return ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(
        _FakeRepo(chapterHtml: html, initialProgress: progress),
      ),
    ]);
  }

  group('图片章节类型判定（provider 层）', () {
    test('纯图章节：图片节点 ≥3 且占比 ≥80% 判定为图片章节', () async {
      final container = makeContainer(html: _imageChapterHtml(5));
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');

      final state = container.read(readerProvider);
      expect(state.isImageChapter, isTrue);
      expect(state.nodes.where((n) => n.type == NodeType.image).length, 5);
    });

    test('边界：恰好 80%（4 图 + 1 段）判定为图片章节，60%（3 图 + 2 段）不算', () async {
      final boundary = makeContainer(
        html: '<p>开篇文字</p>${_imageChapterHtml(4)}',
      );
      addTearDown(boundary.dispose);
      await boundary
          .read(readerProvider.notifier)
          .loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      expect(boundary.read(readerProvider).isImageChapter, isTrue);

      final mixed = makeContainer(
        html: '<p>第一段</p><p>第二段</p>${_imageChapterHtml(3)}',
      );
      addTearDown(mixed.dispose);
      await mixed
          .read(readerProvider.notifier)
          .loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      expect(mixed.read(readerProvider).isImageChapter, isFalse);
    });

    test('图片少于 3 张或纯文本不算图片章节', () async {
      final fewImages = makeContainer(html: _imageChapterHtml(2));
      addTearDown(fewImages.dispose);
      await fewImages
          .read(readerProvider.notifier)
          .loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      expect(fewImages.read(readerProvider).isImageChapter, isFalse);

      final plainText = makeContainer(
        html: '<p>这是一段纯文本内容，没有图片。</p>',
      );
      addTearDown(plainText.dispose);
      await plainText
          .read(readerProvider.notifier)
          .loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      expect(plainText.read(readerProvider).isImageChapter, isFalse);
    });
  });

  group('图片章节跳过文本分页（provider 层）', () {
    test('loadChapter 与 setViewport 均不产生分页页，翻页以图片数为界', () async {
      final container = makeContainer(html: _imageChapterHtml(3));
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      // 视口未上报时不分页
      expect(container.read(readerProvider).pages, isEmpty);

      notifier.setViewport(400, 600);
      var state = container.read(readerProvider);
      // 视口就绪后图片章节仍不分页（pages 恒为空，图片阅读器直接用 nodes）
      expect(state.pages, isEmpty);
      expect(state.isImageChapter, isTrue);
      expect(state.currentPage, 0);

      // 左右翻页以图片数为界：0 → 1 → 2 → 停在 2，回退 1
      notifier.nextPage();
      state = container.read(readerProvider);
      expect(state.currentPage, 1);
      notifier.nextPage();
      state = container.read(readerProvider);
      expect(state.currentPage, 2);
      notifier.nextPage();
      expect(container.read(readerProvider).currentPage, 2);
      notifier.prevPage();
      expect(container.read(readerProvider).currentPage, 1);

      // 越界跳转被忽略
      notifier.jumpToPage(99);
      expect(container.read(readerProvider).currentPage, 1);
      notifier.jumpToPage(2);
      expect(container.read(readerProvider).currentPage, 2);

      // 等待进度防抖定时器落盘，避免测试结束时残留 Timer
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });

    test('横屏（宽 > 高）图片章节仍一次换一张图，不做双栏对齐', () async {
      final container = makeContainer(html: _imageChapterHtml(4));
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      notifier.setViewport(800, 400); // 横屏：文本章节会双栏步长 2

      notifier.nextPage();
      expect(container.read(readerProvider).currentPage, 1);
      notifier.nextPage();
      expect(container.read(readerProvider).currentPage, 2);

      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
  });

  group('图片章节进度保存复用（provider 层）', () {
    test('按保存的图片索引恢复阅读位置', () async {
      final repo = _FakeRepo(
        chapterHtml: _imageChapterHtml(5),
        initialProgress: ReadingProgress(
          bookId: 'b1',
          chapterIndex: 0,
          pageIndex: 2, // 上次读到第 3 张图
          updatedAt: DateTime.now(),
        ),
      );
      final container = ProviderContainer(overrides: [
        readerRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      await container
          .read(readerProvider.notifier)
          .loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      expect(container.read(readerProvider).currentPage, 2);
    });

    test('翻图后经既有进度模型落盘（pageIndex = 图片索引）', () async {
      final repo = _FakeRepo(chapterHtml: _imageChapterHtml(5));
      final container = ProviderContainer(overrides: [
        readerRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      expect(repo.lastSaved, isNull);

      notifier.nextPage();
      // 等待 500ms 防抖落盘窗口
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(repo.lastSaved, isNotNull);
      expect(repo.lastSaved!.bookId, 'b1');
      expect(repo.lastSaved!.chapterIndex, 0);
      expect(repo.lastSaved!.pageIndex, 1);
    });
  });

  group('图片阅读器渲染（widget 层）', () {
    Future<ProviderContainer> pumpImageReader(
      WidgetTester tester, {
      required String html,
    }) async {
      final container = makeContainer(html: html);
      addTearDown(container.dispose);
      await container
          .read(readerProvider.notifier)
          .loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: ImageReaderWidget(),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // postFrame 上报视口（setViewport）
      await tester.pump(); // 状态更新后的重建
      return container;
    }

    testWidgets('3 张图逐页渲染、页码指示、左右滑换图', (tester) async {
      await pumpImageReader(tester, html: _imageChapterHtml(3));

      // 首屏：第 1 张图 + 页码 1/3
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);

      // 左滑 → 第 2 张
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);

      // 左滑 → 第 3 张（末图）
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);

      // 右滑 → 回到第 2 张
      await tester.drag(find.byType(PageView), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);

      // 等待进度防抖定时器落盘，避免测试结束时残留 Timer
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('点击图片切换设置栏（showSettings）', (tester) async {
      final container = await pumpImageReader(tester, html: _imageChapterHtml(3));
      expect(container.read(readerProvider).showSettings, isFalse);

      await tester.tap(find.byType(ImageReaderWidget));
      // onTap 与 onDoubleTap 注册在同一 GestureDetector：单击需等双击超时窗口
      // （300ms）结束后才触发，故先推进假时钟再断言
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(readerProvider).showSettings, isTrue);

      // 等待进度防抖定时器落盘，避免测试结束时残留 Timer
      await tester.pump(const Duration(milliseconds: 600));
    });
  });
}
