import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../domain/entities/book.dart';
import '../../domain/repositories/bookshelf_repository.dart';
import '../models/book_model.dart';

class BookshelfRepositoryImpl implements BookshelfRepository {
  @override
  Future<List<Book>> getAll() async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    return box.values.map((e) => e.toEntity()).toList()
      ..sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
  }

  @override
  Future<Book?> getById(String id) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    final model = box.get(id);
    return model?.toEntity();
  }

  @override
  Future<void> save(Book book) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await box.put(book.id, BookModel.fromEntity(book));
  }

  @override
  Future<void> delete(String id) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await box.delete(id);
  }

  @override
  Future<void> updateProgress(String id, double progress) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    final model = box.get(id);
    if (model != null) {
      final updated = BookModel(
        id: model.id,
        name: model.name,
        author: model.author,
        coverUrl: model.coverUrl,
        sourceId: model.sourceId,
        lastChapter: model.lastChapter,
        progress: progress,
        lastReadAt: DateTime.now(),
      );
      await box.put(id, updated);
    }
  }
}
