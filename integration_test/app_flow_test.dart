import 'dart:io';

import 'package:easy_read/app.dart';
import 'package:easy_read/core/database/hive_init.dart';
import 'package:easy_read/features/book_source/data/models/book_source_model.dart';
import 'package:easy_read/features/bookshelf/data/models/book_model.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Scrollable;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:integration_test/integration_test.dart';

/// 核心链路冒烟测试：启动 → 底部导航 → 设置子页（Cupertino 转场路由）→ 返回。
/// 不依赖具体数据（书架空/有书均可），只验证导航链路与页面渲染不崩溃。
/// 需要先初始化 Hive（与 test/widget_test.dart 一致），否则书架/书源
/// provider 打开盒子会抛错。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    if (!kIsWeb) {
      // 桌面/移动端：临时目录；Web 端 Hive 自动使用 IndexedDB
      final tempDir = Directory.systemTemp.createTempSync('itest_smoke');
      Hive.init(tempDir.path);
    }
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

  testWidgets('启动 + 底部导航 + 路由转场冒烟', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: EasyReadApp()));
    // 等待 Hive 初始化与首页渲染（真机首次启动可能较慢）
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // 首页应为书架（无论空态或列表态，AppBar 标题存在）
    expect(find.text('书架'), findsWidgets);

    // 切到"设置" tab
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('设置'), findsWidgets);

    // 进入"管理净化规则"子页（走 CupertinoPage 转场路由）。
    // 设置列表懒加载，窗口较小时目标项可能在视口外：先滚动到可见再点。
    await tester.scrollUntilVisible(
      find.text('管理净化规则'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('管理净化规则'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('净化规则'), findsWidgets);

    // 返回书架 tab（返回键可回设置页，再切回书架）
    await tester.pageBack();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('书架'), findsWidgets);
  });
}