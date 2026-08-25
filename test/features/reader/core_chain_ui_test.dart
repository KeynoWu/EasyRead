import 'dart:io';

import 'package:easy_read/app.dart';
import 'package:easy_read/core/database/hive_init.dart';
import 'package:easy_read/features/book_source/data/models/book_source_model.dart';
import 'package:easy_read/features/book_source/data/repositories/book_source_repository_impl.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/bookshelf/data/models/book_model.dart';
import 'package:easy_read/features/bookshelf/data/repositories/bookshelf_repository_impl.dart';
import 'package:easy_read/features/bookshelf/data/services/book_detail_service.dart'
    show BookDetail, BookDetailService;
import 'package:easy_read/features/bookshelf/domain/entities/book.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/book_detail.dart' as reader;
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:easy_read/features/bookshelf/presentation/providers/bookshelf_provider.dart';
import 'package:easy_read/features/book_source/presentation/providers/book_source_provider.dart';
import 'package:flutter/material.dart' show Icons, Scaffold;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 核心链路 UI 验收：书架 → 详情（目录折叠）→ 阅读（正文渲染）。
/// 注入 fake 数据源驱动真实 UI；重点验证"不再整页 HTML、正文正常解析渲染"。
class _FakeBookshelfRepo extends BookshelfRepositoryImpl {
  final List<Book> books;
  _FakeBookshelfRepo(this.books);

  @override
  Future<List<Book>> getAll() async => books;
  @override
  Future<Book?> getById(String id) async {
    for (final b in books) {
      if (b.id == id) return b;
    }
    return null;
  }
  @override
  Future<void> save(Book book) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> deleteAll(List<String> ids) async {}
  @override
  Future<void> updateProgress(String id, double progress) async {}
}

class _FakeSourceRepo extends BookSourceRepositoryImpl {
  final List<BookSource> sources;
  _FakeSourceRepo(this.sources);

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
  Future<List<BookSource>> getEnabled() async => sources;
  @override
  Future<void> save(BookSource source) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> importFromJson(String jsonString) async {}
  @override
  Future<void> importFromUrl(String url) async {}
}

class _FakeDetailService extends BookDetailService {
  final BookDetail? detail;
  _FakeDetailService(this.detail);

  @override
  Future<BookDetail?> get(String bookId) async => detail;
  @override
  Future<void> save(
    String bookId, {
    String? detailUrl,
    String? alternativesJson,
    String? variablesJson,
  }) async {}
  @override
  Future<void> remove(String bookId) async {}
}

class _FakeReaderRepo extends ReaderRepositoryImpl {
  @override
  Future<reader.BookDetail> getBookDetail({
    required String bookId,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return reader.BookDetail(bookId: bookId, name: '测试小说', intro: '这是一段简介。');
  }

  @override
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return ChapterCatalog(
      bookId: bookId,
      fetchedAt: DateTime(2026, 1, 1),
      chapters: const [
        ChapterItem(title: '第一章 起', url: 'u1', index: 0),
        ChapterItem(title: '第二章 承', url: 'u2', index: 1),
      ],
    );
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => null;

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return Chapter(
      id: 'c-$chapterIndex',
      bookId: bookId,
      title: chapterIndex == 0 ? '第一章 起' : '第二章 承',
      content: '这是第一章的正文内容。主角登场，故事开始。$chapterIndex',
      index: chapterIndex,
      sourceId: sourceId,
      cachedAt: DateTime.now(),
    );
  }

  @override
  Future<void> clearBookCache(String bookId) async {}
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('core_chain_ui');
    Hive.init(tempDir.path);
    Hive.registerAdapter(BookModelAdapter());
    Hive.registerAdapter(BookSourceModelAdapter());
    Hive.registerAdapter(ChapterModelAdapter());
    Hive.registerAdapter(ReadingProgressModelAdapter());
    await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await openSensitiveBox<BookSourceModel>(HiveBoxes.bookSources);
    await openSensitiveBox(HiveBoxes.settings);
    await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
    await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
    // 阅读器设置盒（loadPersistedSettings 打开；预开避免测试时钟下 IO 挂起）
    await Hive.openBox<dynamic>('reader_settings');
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('核心链路：书架→详情（目录折叠）→阅读（正文渲染，非整页HTML）', (tester) async {
    final book = Book(
      id: 'book1',
      name: '测试小说',
      author: '作者',
      sourceId: 'src1',
      lastReadAt: DateTime(2026, 1, 1),
    );
    const source = BookSource(
      id: 'src1',
      name: '测试源',
      bookSourceUrl: 'https://example.com',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookshelfRepositoryProvider.overrideWithValue(_FakeBookshelfRepo([book])),
          bookSourceRepositoryProvider.overrideWithValue(_FakeSourceRepo([source])),
          bookDetailServiceProvider.overrideWithValue(
            _FakeDetailService(const BookDetail(detailUrl: 'https://example.com/book/1')),
          ),
          readerRepositoryProvider.overrideWithValue(_FakeReaderRepo()),
        ],
        child: const EasyReadApp(),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }
    await settle();

    // 1) 书架显示书
    expect(find.text('测试小说'), findsWidgets);

    // 2) 长按 → 查看详情
    await tester.longPress(find.text('测试小说').first);
    await settle();
    await tester.tap(find.text('查看详情'));
    await settle();

    // 3) 详情页：开始阅读 + 目录折叠（不显示章节项）
    expect(find.text('开始阅读'), findsOneWidget);
    expect(find.text('目录（2）'), findsOneWidget);
    expect(find.text('第一章 起'), findsNothing);

    // 4) 展开目录验证
    await tester.tap(find.text('目录（2）'));
    await settle();
    expect(find.text('第一章 起'), findsOneWidget);

    // 5) 开始阅读 → 阅读页正文渲染（非错误态、非整页 HTML）
    await tester.tap(find.text('开始阅读'));
    await tester.pump();
    // 阅读器加载链含真实 Hive IO（设置/进度/缓存），runAsync 驱动真实事件循环
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // 章节标题插入正文顶部（_parseChapterContent 的 heading 节点）
    expect(find.text('第一章 起'), findsOneWidget);
    // 段落首行缩进：两个全角空格前缀
    expect(find.textContaining('　　这是第一章的正文内容'), findsWidgets);
    // 底部章节导航按钮（上一章/下一章）
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
    // 标题几何居中（防回归：Column start 对齐曾使 Text 的 textAlign 失效）。
    // 默认测试表面 800x600 为横屏双栏：标题在左栏（半宽）内居中。
    final scaffoldSize = tester.getSize(find.byType(Scaffold));
    final expectedCenterX =
        scaffoldSize.width > scaffoldSize.height
            ? scaffoldSize.width / 4
            : scaffoldSize.width / 2;
    expect(
      tester.getCenter(find.text('第一章 起')).dx,
      closeTo(expectedCenterX, 1.5),
    );

    // 退出阅读器：让 ReaderPage.dispose 的进度同步在 provider 存活期完成，
    // 避免 teardown 时 ProviderScope dispose 与未完成回调竞争（Riverpod 3 限制）
    // 点正文中间呼出菜单（顶栏随之显示，返回按钮可用）
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });
}
