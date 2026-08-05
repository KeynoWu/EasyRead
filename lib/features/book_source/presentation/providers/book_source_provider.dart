import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/book_source_repository_impl.dart';
import '../../data/services/book_source_test_store.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/entities/book_source_test_record.dart';

final bookSourceRepositoryProvider = Provider<BookSourceRepositoryImpl>((ref) {
  return BookSourceRepositoryImpl();
});

final bookSourceListProvider = FutureProvider<List<BookSource>>((ref) async {
  final repo = ref.watch(bookSourceRepositoryProvider);
  return repo.getAll();
});

/// 书源检测结果存储（批量检测结果的持久化与读取）
final bookSourceTestStoreProvider = Provider<BookSourceTestStore>((ref) {
  return BookSourceTestStore();
});

/// 全部检测结果（key = 书源 id）
final bookSourceTestRecordsProvider =
    FutureProvider<Map<String, BookSourceTestRecord>>((ref) {
  return ref.watch(bookSourceTestStoreProvider).getAll();
});
