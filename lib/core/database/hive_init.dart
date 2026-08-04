import 'package:hive_flutter/hive_flutter.dart';
import '../../features/bookshelf/data/models/book_model.dart';
import '../../features/book_source/data/models/book_source_model.dart';
import '../../features/reader/data/models/chapter_model.dart';
import '../../features/reader/data/models/reading_progress_model.dart';

/// Hive 盒子名称常量
class HiveBoxes {
  static const String bookshelf = 'bookshelf';
  static const String bookSources = 'book_sources';
  static const String settings = 'settings';
  static const String chapters = 'chapters';
  static const String readingProgress = 'reading_progress';
}

/// 初始化 Hive 存储
Future<void> initHive() async {
  await Hive.initFlutter();
  Hive.registerAdapter(BookModelAdapter());
  Hive.registerAdapter(BookSourceModelAdapter());
  Hive.registerAdapter(ChapterModelAdapter());
  Hive.registerAdapter(ReadingProgressModelAdapter());
  await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
  await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
  await Hive.openBox(HiveBoxes.settings);
  await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
  await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
}
