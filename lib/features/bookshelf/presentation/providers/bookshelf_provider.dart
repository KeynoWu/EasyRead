import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/bookshelf_repository_impl.dart';
import '../../domain/entities/book.dart';

final bookshelfRepositoryProvider = Provider<BookshelfRepositoryImpl>((ref) {
  return BookshelfRepositoryImpl();
});

final bookshelfListProvider = FutureProvider<List<Book>>((ref) async {
  final repo = ref.watch(bookshelfRepositoryProvider);
  return repo.getAll();
});
