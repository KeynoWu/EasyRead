import '../entities/search_result.dart';
import '../repositories/search_repository.dart';
import '../../../book_source/domain/repositories/book_source_repository.dart';

class SearchBooks {
  final SearchRepository searchRepo;
  final BookSourceRepository sourceRepo;

  SearchBooks({required this.searchRepo, required this.sourceRepo});

  Future<List<SearchResult>> execute(String keyword, String sourceId) async {
    if (keyword.trim().isEmpty) return [];
    return searchRepo.search(keyword.trim(), sourceId);
  }
}
