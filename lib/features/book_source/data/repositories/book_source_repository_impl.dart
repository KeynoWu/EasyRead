import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/repositories/book_source_repository.dart';
import '../models/book_source_model.dart';

class BookSourceRepositoryImpl implements BookSourceRepository {
  late final Box<BookSourceModel> _box;

  @override
  Future<List<BookSource>> getAll() async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    return _box.values.map((e) => e.toEntity()).toList();
  }

  @override
  Future<BookSource?> getById(String id) async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    final model = _box.get(id);
    return model?.toEntity();
  }

  @override
  Future<void> save(BookSource source) async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    await _box.put(source.id, BookSourceModel.fromEntity(source));
  }

  @override
  Future<void> delete(String id) async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    await _box.delete(id);
  }

  @override
  Future<void> importFromJson(String jsonString) async {
    // 由 ImportBookSource usecase 处理
  }

  @override
  Future<void> importFromUrl(String url) async {
    // Phase 2 实现
  }

  @override
  Future<List<BookSource>> getEnabled() async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    return _box.values.where((e) => e.enabled).map((e) => e.toEntity()).toList();
  }
}
