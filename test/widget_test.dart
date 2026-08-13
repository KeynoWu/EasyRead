import 'dart:io';

import 'package:easy_read/app.dart';
import 'package:easy_read/core/database/hive_init.dart';
import 'package:easy_read/features/book_source/data/models/book_source_model.dart';
import 'package:easy_read/features/book_source/data/models/source_subscription_model.dart';
import 'package:easy_read/features/bookshelf/data/models/book_model.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    Hive.init(Directory.systemTemp.createTempSync('widget_smoke').path);
    Hive.registerAdapter(BookModelAdapter());
    Hive.registerAdapter(BookSourceModelAdapter());
    Hive.registerAdapter(SourceSubscriptionModelAdapter());
    Hive.registerAdapter(ChapterModelAdapter());
    Hive.registerAdapter(ReadingProgressModelAdapter());
    await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await openSensitiveBox<BookSourceModel>(HiveBoxes.bookSources);
    await openSensitiveBox(HiveBoxes.settings);
    await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
    await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
    await openSensitiveBox<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
  });

  tearDownAll(() async {
    await Hive.close();
  });

  testWidgets('App 启动后书架页正常渲染', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: EasyReadApp()));
    await tester.pumpAndSettle();

    expect(find.text('书架'), findsWidgets);
    expect(find.text('书架空空'), findsOneWidget);
    expect(find.text('去搜索添加书籍，或导入本地 TXT/EPUB'), findsOneWidget);
  });
}
