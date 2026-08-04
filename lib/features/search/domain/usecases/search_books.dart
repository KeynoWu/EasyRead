import 'dart:async';
import '../entities/search_result.dart';
import '../repositories/search_repository.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';

class SearchBooks {
  final SearchRepository searchRepo;
  final BookSourceRepository sourceRepo;

  SearchBooks({required this.searchRepo, required this.sourceRepo});

  /// 单源搜索
  Future<List<SearchResult>> execute(String keyword, String sourceId) async {
    if (keyword.trim().isEmpty) return [];
    final source = await sourceRepo.getById(sourceId);
    if (source == null || !source.enabled) return [];
    return searchRepo.searchWithSource(keyword.trim(), source);
  }

  /// 多源聚合搜索（并发分发 + 按 书名|作者 分组去重）
  Future<List<SearchResult>> executeMultiSource(String keyword) async {
    if (keyword.trim().isEmpty) return [];

    final sources = await sourceRepo.getEnabled();
    if (sources.isEmpty) return [];

    // 每个源独立超时，慢源不阻塞整体结果
    final futures = sources.map((source) => searchRepo
        .searchWithSource(keyword, source)
        .timeout(const Duration(seconds: 10), onTimeout: () => <SearchResult>[]));
    final results = await Future.wait(futures);

    // 按 书名|作者 分组：同名同作者视为同一本书，其余作为替代书源
    final groups = <String, List<SearchResult>>{};
    for (final resultList in results) {
      for (final result in resultList) {
        final key = '${result.name.toLowerCase().trim()}|${result.author?.toLowerCase().trim() ?? ''}';
        groups.putIfAbsent(key, () => []).add(result);
      }
    }

    final deduplicated = <SearchResult>[];
    for (final entry in groups.entries) {
      final list = entry.value;
      final primary = list.first;
      final alternatives = list.skip(1).map((r) => SourceOption(
        bookId: r.bookId,
        sourceId: r.sourceId,
        sourceName: r.sourceName,
        detailUrl: r.detailUrl,
      )).toList();
      deduplicated.add(SearchResult(
        bookId: primary.bookId,
        name: primary.name,
        author: primary.author,
        coverUrl: primary.coverUrl,
        detailUrl: primary.detailUrl,
        sourceId: primary.sourceId,
        sourceName: primary.sourceName,
        alternatives: alternatives,
      ));
    }

    return deduplicated;
  }
}
