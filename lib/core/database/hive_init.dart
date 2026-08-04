import 'package:hive_flutter/hive_flutter.dart';
import '../../features/bookshelf/data/models/book_model.dart';
import '../../features/book_source/data/models/book_source_model.dart';

/// Hive 盒子名称常量
class HiveBoxes {
  static const String bookshelf = 'bookshelf';
  static const String bookSources = 'book_sources';
  static const String settings = 'settings';
}

/// 初始化 Hive 存储
Future<void> initHive() async {
  await Hive.initFlutter();

  // 注册 TypeAdapter（手动实现，避免 hive_generator 兼容性问题）
  Hive.registerAdapter(BookModelAdapter());
  Hive.registerAdapter(BookSourceModelAdapter());

  await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
  await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
  await Hive.openBox(HiveBoxes.settings);
}
