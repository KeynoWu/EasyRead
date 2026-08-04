import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/usecases/search_books.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
import '../../data/repositories/search_repository_impl.dart';

final searchRepositoryProvider = Provider<SearchRepositoryImpl>((ref) {
  return SearchRepositoryImpl();
});

final searchBooksProvider = Provider<SearchBooks>((ref) {
  return SearchBooks(
    searchRepo: ref.watch(searchRepositoryProvider),
    sourceRepo: ref.watch(bookSourceRepositoryProvider),
  );
});

final searchResultsProvider = FutureProvider.family<List<SearchResult>, String>((ref, keyword) async {
  if (keyword.trim().isEmpty) return [];
  final searchBooks = ref.watch(searchBooksProvider);
  return searchBooks.execute(keyword, '');
});
