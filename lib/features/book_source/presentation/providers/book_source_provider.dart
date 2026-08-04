import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/book_source_repository_impl.dart';
import '../../domain/entities/book_source.dart';

final bookSourceRepositoryProvider = Provider<BookSourceRepositoryImpl>((ref) {
  return BookSourceRepositoryImpl();
});

final bookSourceListProvider = FutureProvider<List<BookSource>>((ref) async {
  final repo = ref.watch(bookSourceRepositoryProvider);
  return repo.getAll();
});
