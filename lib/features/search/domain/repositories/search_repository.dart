import '../entities/search_result.dart';

abstract class SearchRepository {
  Future<List<SearchResult>> search(String keyword, String sourceId);
}
