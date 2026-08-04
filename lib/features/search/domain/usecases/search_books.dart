import '../entities/search_result.dart';
import '../repositories/search_repository.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';
import '../../data/repositories/search_repository_impl.dart';

class SearchBooks {
  final SearchRepository searchRepo;
  final BookSourceRepository sourceRepo;

  SearchBooks({required this.searchRepo, required this.sourceRepo});

  /// 单源搜索
  Future<List<SearchResult>> execute(String keyword, String sourceId) async {
    if (keyword.trim().isEmpty) return [];
    return searchRepo.search(keyword.trim(), sourceId);
  }

  /// 多源聚合搜索
  Future<List<SearchResult>> executeMultiSource(String keyword) async {
    if (keyword.trim().isEmpty) return [];

    final sources = await sourceRepo.getEnabled();
    if (sources.isEmpty) return [];

    final searchImpl = searchRepo as SearchRepositoryImpl;

    final futures = sources.map((source) => searchImpl.searchWithSource(keyword, source));
    final results = await Future.wait(futures);

    final allResults = <SearchResult>[];
    for (final resultList in results) {
      allResults.addAll(resultList);
    }

    final seen = <String>{};
    final deduplicated = <SearchResult>[];
    for (final result in allResults) {
      final key = result.name.toLowerCase().trim();
      if (seen.add(key)) {
        deduplicated.add(result);
      }
    }

    return deduplicated;
  }
}
