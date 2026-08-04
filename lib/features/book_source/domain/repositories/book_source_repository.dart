import '../entities/book_source.dart';

abstract class BookSourceRepository {
  Future<List<BookSource>> getAll();
  Future<BookSource?> getById(String id);
  Future<void> save(BookSource source);
  Future<void> delete(String id);
  Future<void> importFromJson(String jsonString);
  Future<void> importFromUrl(String url);
  Future<List<BookSource>> getEnabled();
}
