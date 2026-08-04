import '../../../../features/book_source/domain/entities/book_source.dart';
import '../entities/search_result.dart';

abstract class SearchRepository {
  /// 使用书源配置执行搜索（单源）。返回原始结果，由用例层负责聚合去重。
  Future<List<SearchResult>> searchWithSource(String keyword, BookSource source);
}
