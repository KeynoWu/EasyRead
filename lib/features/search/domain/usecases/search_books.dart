import 'dart:async';
import 'package:dio/dio.dart';
import '../entities/search_result.dart';
import '../repositories/search_repository.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';

/// 流式搜索进度：每完成一个书源返回一次累积结果
class SearchProgress {
  final List<SearchResult> results;
  final int completed;
  final int total;
  final bool finished;

  const SearchProgress({
    required this.results,
    required this.completed,
    required this.total,
    required this.finished,
  });

  static const empty = SearchProgress(results: [], completed: 0, total: 0, finished: true);
}

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

  /// 流式聚合搜索：每个书源完成即产出累积去重结果，慢源不阻塞首屏。
  /// 与 [executeMultiSource] 的去重语义一致（按 书名|作者 分组，后到的
  /// 作为替代源追加），仅产出时机不同。
  Stream<SearchProgress> searchWithProgress(
    String keyword, {
    CancelToken? cancelToken,
  }) {
    final controller = StreamController<SearchProgress>();

    Future<void> run() async {
      if (keyword.trim().isEmpty) {
        controller.add(SearchProgress.empty);
        await controller.close();
        return;
      }

      final sources = (await sourceRepo.getEnabled())
          .where((source) => source.searchable)
          .toList()
        ..sort((a, b) => (b.searchWeight ?? 0).compareTo(a.searchWeight ?? 0));
      if (sources.isEmpty) {
        controller.add(SearchProgress.empty);
        await controller.close();
        return;
      }

      const maxConcurrent = 4;
      final groups = <String, SearchResult>{};
      final order = <String>[];
      var completed = 0;
      var nextIndex = 0;

      Future<void> worker() async {
        while (true) {
          if (cancelToken?.isCancelled ?? false) return;
          final index = nextIndex++;
          if (index >= sources.length) return;
          final source = sources[index];
          final results = await searchRepo
              .searchWithSource(keyword, source, cancelToken: cancelToken)
              .timeout(const Duration(seconds: 10),
                  onTimeout: () => <SearchResult>[]);

          // 增量合并去重
          for (final r in results) {
            final key =
                '${r.name.toLowerCase().trim()}|${r.author?.toLowerCase().trim() ?? ''}';
            final existing = groups[key];
            if (existing == null) {
              groups[key] = r;
              order.add(key);
            } else {
              groups[key] = SearchResult(
                bookId: existing.bookId,
                name: existing.name,
                author: existing.author,
                coverUrl: existing.coverUrl,
                detailUrl: existing.detailUrl,
                sourceId: existing.sourceId,
                sourceName: existing.sourceName,
                alternatives: [
                  ...existing.alternatives,
                  SourceOption(
                    bookId: r.bookId,
                    sourceId: r.sourceId,
                    sourceName: r.sourceName,
                    detailUrl: r.detailUrl,
                  ),
                ],
              );
            }
          }

          completed++;
          controller.add(SearchProgress(
            results: [for (final k in order) groups[k]!],
            completed: completed,
            total: sources.length,
            finished: completed >= sources.length,
          ));
        }
      }

      final workers = <Future<void>>[
        for (var i = 0; i < maxConcurrent && i < sources.length; i++) worker(),
      ];
      await Future.wait(workers);
      if (!controller.isClosed) {
        controller.add(SearchProgress(
          results: [for (final k in order) groups[k]!],
          completed: completed,
          total: sources.length,
          finished: true,
        ));
        await controller.close();
      }
    }

    run().catchError((Object e) {
      if (!controller.isClosed) {
        controller.addError(e);
        controller.close();
      }
    });
    return controller.stream;
  }
}
