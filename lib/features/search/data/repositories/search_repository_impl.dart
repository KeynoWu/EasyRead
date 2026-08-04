import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/search_repository.dart';
import '../engines/rule_engine.dart';

class SearchRepositoryImpl implements SearchRepository {
  final DioClient _client;
  final PurifyPipeline _pipeline;

  SearchRepositoryImpl({DioClient? client, PurifyPipeline? pipeline})
      : _client = client ?? DioClient(),
        _pipeline = pipeline ?? PurifyPipeline();

  @override
  Future<List<SearchResult>> search(String keyword, String sourceId) async {
    return [];
  }

  /// 使用书源配置执行搜索
  Future<List<SearchResult>> searchWithSource(String keyword, BookSource source) async {
    if (!source.enabled || source.searchUrl == null || source.bookListRule == null) {
      return [];
    }

    try {
      final url = source.searchUrl!.replaceAll('{{key}}', Uri.encodeComponent(keyword));
      final html = await _client.getString(url, sourceId: source.id);

      final items = RuleEngine.extractElements(html, source.bookListRule);
      final results = <SearchResult>[];

      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item == null) continue;

        final name = RuleEngine.getElementText(item, source.bookNameRule);
        if (name == null || name.isEmpty) continue;

        results.add(SearchResult(
          bookId: '${source.id}_$i',
          name: name,
          author: RuleEngine.getElementText(item, source.bookAuthorRule),
          coverUrl: RuleEngine.getElementText(item, source.coverUrlRule),
          detailUrl: RuleEngine.getElementText(item, source.bookDetailUrlRule),
          sourceId: source.id,
          sourceName: source.name,
        ));
      }

      return results;
    } catch (e) {
      return [];
    }
  }
}
