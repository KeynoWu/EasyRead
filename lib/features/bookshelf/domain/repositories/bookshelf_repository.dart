import '../entities/book.dart';

abstract class BookshelfRepository {
  Future<List<Book>> getAll();
  Future<Book?> getById(String id);
  Future<void> save(Book book);
  Future<void> delete(String id);
  Future<void> updateProgress(String id, double progress);
}
