import 'dart:async';
import 'package:dio/dio.dart';
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

  /// 多源聚合搜索（并发上限 4 + 按 书名|作者 分组去重）
  /// [cancelToken] 透传给每个源的网络请求，供上层换词时取消旧批次。
  Future<List<SearchResult>> executeMultiSource(String keyword, {CancelToken? cancelToken}) async {
    if (keyword.trim().isEmpty) return [];

    final sources = (await sourceRepo.getEnabled())
        .where((source) => source.searchable)
        .toList()
      ..sort((a, b) => (b.searchWeight ?? 0).compareTo(a.searchWeight ?? 0));
    if (sources.isEmpty) return [];

    // 全局并发信号量：最多 4 个源同时请求，其余排队；
    // 每个源独立超时（10s），慢源不阻塞整体结果；取消时底层请求被真正中断。
    const maxConcurrent = 4;
    final results = <List<SearchResult>>[];
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= sources.length) return;
        final source = sources[index];
        final list = await searchRepo
            .searchWithSource(keyword, source, cancelToken: cancelToken)
            .timeout(const Duration(seconds: 10), onTimeout: () => <SearchResult>[]);
        results.add(list);
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < maxConcurrent && i < sources.length; i++) worker(),
    ];
    await Future.wait(workers);

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
