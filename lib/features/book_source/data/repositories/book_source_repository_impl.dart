import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/repositories/book_source_repository.dart';
import '../models/book_source_model.dart';

class BookSourceRepositoryImpl implements BookSourceRepository {
  Box<BookSourceModel>? _cachedBox;

  Future<Box<BookSourceModel>> _box() async {
    return _cachedBox ??= await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
  }

  @override
  Future<List<BookSource>> getAll() async {
    final box = await _box();
    return box.values.map((e) => e.toEntity()).toList();
  }

  @override
  Future<BookSource?> getById(String id) async {
    final box = await _box();
    final model = box.get(id);
    return model?.toEntity();
  }

  @override
  Future<void> save(BookSource source) async {
    final box = await _box();
    await box.put(source.id, BookSourceModel.fromEntity(source));
  }

  @override
  Future<void> delete(String id) async {
    final box = await _box();
    await box.delete(id);
  }

  @override
  Future<void> importFromJson(String jsonString) async {
    // 由 ImportBookSource usecase 处理
  }

  @override
  Future<void> importFromUrl(String url) async {
    // 由 ImportBookSource usecase 处理
  }

  @override
  Future<List<BookSource>> getEnabled() async {
    final box = await _box();
    return box.values.where((e) => e.enabled).map((e) => e.toEntity()).toList();
  }
}
