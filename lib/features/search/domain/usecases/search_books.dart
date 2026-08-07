import 'dart:async';
import 'package:dio/dio.dart';
import '../entities/search_result.dart';
import '../repositories/search_repository.dart';
import '../../../../features/book_source/data/services/book_source_test_store.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../../../features/book_source/domain/entities/book_source_test_record.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';

/// 流式搜索进度：每完成一个书源返回一次累积结果
class SearchProgress {
  final List<SearchResult> results;
  final int completed;
  final int total;
  final bool finished;
  /// 单源请求失败/超时计数：用于区分"全部失败"与"真无结果"
  final int failed;

  const SearchProgress({
    required this.results,
    required this.completed,
    required this.total,
    required this.finished,
    this.failed = 0,
  });

  static const empty = SearchProgress(results: [], completed: 0, total: 0, finished: true);
}

class SearchBooks {
  final SearchRepository searchRepo;
  final BookSourceRepository sourceRepo;
  final BookSourceTestStore? testStore;

  SearchBooks({
    required this.searchRepo,
    required this.sourceRepo,
    this.testStore,
  });

  /// 可参与搜索的源：开启 + 可搜索 + （未被检测 或 检测可用）。
  /// 检测为不可用的源被排除（用户手动启用已测源的场景除外——可用性以
  /// 最近一次检测为准）。
  static bool isSearchableSource(
    BookSource source,
    Map<String, BookSourceTestRecord> records,
  ) {
    if (!source.enabled || !source.searchable) return false;
    final record = records[source.id];
    return record == null || record.usable;
  }

  /// 加载检测记录（未注入 testStore 时返回空表，等价不过滤检测结果）
  Future<Map<String, BookSourceTestRecord>> _testRecords() async {
    return testStore == null ? const {} : await testStore!.getAll();
  }

  /// 单源搜索
  Future<List<SearchResult>> execute(String keyword, String sourceId, {int page = 1}) async {
    if (keyword.trim().isEmpty) return [];
    final source = await sourceRepo.getById(sourceId);
    if (source == null || !source.enabled) return [];
    return searchRepo.searchWithSource(keyword.trim(), source, page: page);
  }

  /// 多源聚合搜索（并发上限 4 + 按 书名|作者 分组去重）
  /// [cancelToken] 透传给每个源的网络请求，供上层换词时取消旧批次。
  Future<List<SearchResult>> executeMultiSource(
    String keyword, {
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    if (keyword.trim().isEmpty) return [];

    final records = await _testRecords();
    final sources = (await sourceRepo.getEnabled())
        .where((source) => isSearchableSource(source, records))
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
            .searchWithSource(
              keyword,
              source,
              page: page,
              cancelToken: cancelToken,
            )
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
        intro: primary.intro,
        kind: primary.kind,
        lastChapter: primary.lastChapter,
        wordCount: primary.wordCount,
        sourceId: primary.sourceId,
        sourceName: primary.sourceName,
        variables: primary.variables,
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
    int page = 1,
    CancelToken? cancelToken,
  }) {
    final controller = StreamController<SearchProgress>();

    Future<void> run() async {
      if (keyword.trim().isEmpty) {
        controller.add(SearchProgress.empty);
        await controller.close();
        return;
      }

      final records = await _testRecords();
      final sources = (await sourceRepo.getEnabled())
          .where((source) => isSearchableSource(source, records))
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
      var failed = 0;
      var nextIndex = 0;

      Future<void> worker() async {
        while (true) {
          if (cancelToken?.isCancelled ?? false) return;
          final index = nextIndex++;
          if (index >= sources.length) return;
          final source = sources[index];
          List<SearchResult> results;
          try {
            results = await searchRepo
                .searchWithSource(
                  keyword,
                  source,
                  page: page,
                  cancelToken: cancelToken,
                  throwOnError: true,
                )
                .timeout(const Duration(seconds: 10));
          } catch (e) {
            // 主动取消直接退出，不计失败（取消途经请求不应被误报不可用）
            if (cancelToken?.isCancelled ?? false) return;
            failed++;
            completed++;
            controller.add(SearchProgress(
              results: [for (final k in order) groups[k]!],
              completed: completed,
              total: sources.length,
              failed: failed,
              finished: completed >= sources.length,
            ));
            continue;
          }
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
                intro: existing.intro,
                kind: existing.kind,
                lastChapter: existing.lastChapter,
                wordCount: existing.wordCount,
              sourceId: existing.sourceId,
              sourceName: existing.sourceName,
              variables: existing.variables,
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
            failed: failed,
            finished: completed >= sources.length,
          ));
        }
      }

      final workers = <Future<void>>[
        for (var i = 0; i < maxConcurrent && i < sources.length; i++) worker(),
      ];
      await Future.wait(workers);
      if (!controller.isClosed) {
        // 取消后不发 finished: true 的残缺进度（completed < total）：
        // 调用方已换词/销毁，直接关闭流即可
        if (cancelToken?.isCancelled ?? false) {
          await controller.close();
          return;
        }
        controller.add(SearchProgress(
          results: [for (final k in order) groups[k]!],
          completed: completed,
          total: sources.length,
          failed: failed,
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
