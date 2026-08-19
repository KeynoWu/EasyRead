import 'dart:io';

import 'package:easy_read/app.dart';
import 'package:easy_read/core/database/hive_init.dart';
import 'package:easy_read/features/book_source/data/models/book_source_model.dart';
import 'package:easy_read/features/bookshelf/data/models/book_model.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('widget_smoke');
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
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('App 启动后书架页正常渲染', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: EasyReadApp()));
    await tester.pumpAndSettle();

    expect(find.text('书架'), findsWidgets);
    expect(find.text('书架空空'), findsOneWidget);
    expect(find.text('去搜索添加书籍'), findsOneWidget);
  });

  testWidgets('底部导航全 tab 冒烟：书架→搜索→书源→设置→净化规则页', (tester) async {
    // 显式 pump 步进：搜索页有加载动画，pumpAndSettle 会因动画不收敛而超时
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tester.pumpWidget(const ProviderScope(child: EasyReadApp()));
    await settle();

    // 首页：书架
    expect(find.text('书架空空'), findsOneWidget);

    // 搜索 tab
    await tester.tap(find.text('搜索'));
    await settle();
    expect(find.text('搜索'), findsWidgets);

    // 书源 tab
    await tester.tap(find.text('书源'));
    await settle();
    expect(find.text('书源'), findsWidgets);

    // 设置 tab
    await tester.tap(find.text('设置'));
    await settle();
    expect(find.text('设置'), findsWidgets);

    // 进入净化规则子页（Cupertino 转场路由）
    await tester.tap(find.text('管理净化规则'));
    await settle();
    expect(find.text('管理净化规则'), findsWidgets);

    // 返回设置 → 切回书架
    await tester.pageBack();
    await settle();
    await tester.tap(find.text('书架'));
    await settle();
    expect(find.text('书架空空'), findsOneWidget);
  });
}