import 'dart:convert';
import '../../../../core/network/dio_client.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/search_repository.dart';
import '../engines/rule_engine.dart';

class SearchRepositoryImpl implements SearchRepository {
  final DioClient _client;

  SearchRepositoryImpl({DioClient? client})
      : _client = client ?? DioClient();

  @override
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

        final detailUrl = RuleEngine.getElementText(item, source.bookDetailUrlRule);
        results.add(SearchResult(
          bookId: _stableBookId(source.id, detailUrl, i),
          name: name,
          author: RuleEngine.getElementText(item, source.bookAuthorRule),
          coverUrl: RuleEngine.getElementText(item, source.coverUrlRule),
          detailUrl: detailUrl,
          sourceId: source.id,
          sourceName: source.name,
        ));
      }

      return results;
    } catch (e) {
      return [];
    }
  }

  /// 基于详情 URL 生成稳定书 ID：同一本书在不同搜索中保持同一 ID，
  /// 避免列表索引变化导致缓存与阅读进度错位。
  static String _stableBookId(String sourceId, String? detailUrl, int index) {
    if (detailUrl != null && detailUrl.isNotEmpty) {
      return '${sourceId}_${base64Url.encode(utf8.encode(detailUrl))}';
    }
    return '${sourceId}_$index';
  }
}
