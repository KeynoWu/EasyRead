import 'dart:async';
import 'package:dio/dio.dart';
import '../entities/book_source.dart';
import '../entities/book_source_test_record.dart';
import 'test_book_source.dart';
import '../../data/services/book_source_test_store.dart';

/// 批量检测进度
class BatchTestProgress {
  final int done;
  final int total;
  final BookSource current;
  final BookSourceTestRecord result;

  const BatchTestProgress({
    required this.done,
    required this.total,
    required this.current,
    required this.result,
  });
}

/// 批量检测汇总
class BatchTestSummary {
  final int total;
  final int usable;
  final int unusable;
  final int skipped;

  /// 失败原因分类（不可用源的 error 归类计数）
  final int timeoutCount;
  final int networkErrorCount;
  final int noResultCount;
  final int configErrorCount;

  const BatchTestSummary({
    required this.total,
    required this.usable,
    required this.unusable,
    required this.skipped,
    this.timeoutCount = 0,
    this.networkErrorCount = 0,
    this.noResultCount = 0,
    this.configErrorCount = 0,
  });
}

/// 批量检测书源：受限并发逐个实测搜索，结果持久化到 [BookSourceTestStore]。
///
/// 说明：检测请求按书源自身 source_id 走 DioClient 限频拦截器，
/// 并发数受 [maxConcurrent] 限制，实际吞吐受各源限频与网络耗时影响。
class BatchTestBookSources {
  final TestBookSource tester;
  final BookSourceTestStore store;

  /// 检测并发上限
  static const int maxConcurrent = 6;

  /// 单源检测超时（超出判定不可用）
  static const Duration perSourceTimeout = Duration(seconds: 8);

  /// 检测统一关键词（保证源间可比性）
  static const String testKeyword = '小说';

  BatchTestBookSources({
    TestBookSource? tester,
    BookSourceTestStore? store,
  })  : tester = tester ?? TestBookSource(),
        store = store ?? BookSourceTestStore();

  /// 执行批量检测。跳过缺少搜索能力的书源（计入 skipped）。
  Future<BatchTestSummary> run({
    required List<BookSource> sources,
    void Function(BatchTestProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final testable = <BookSource>[];
    var skipped = 0;
    for (final source in sources) {
      if (!source.enabled || source.searchUrl == null || source.bookListRule == null) {
        skipped++;
        continue;
      }
      testable.add(source);
    }

    var done = 0;
    var usable = 0;
    var unusable = 0;
    var timeoutCount = 0;
    var networkErrorCount = 0;
    var noResultCount = 0;
    var configErrorCount = 0;
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken?.isCancelled ?? false) return;
        final index = nextIndex++;
        if (index >= testable.length) return;
        final source = testable[index];

        final record = await _testOne(source, cancelToken);
        // 取消后在途请求的结果不落库，避免已取消的源被标记为不可用
        if (cancelToken?.isCancelled ?? false) return;
        await store.save(source.id, record);
        done++;
        if (record.usable) {
          usable++;
        } else {
          unusable++;
          final error = record.error ?? '';
          if (error.contains('超时')) {
            timeoutCount++;
          } else if (error.startsWith('请求失败')) {
            networkErrorCount++;
          } else if (error.contains('未解析到结果')) {
            // 请求成功但规则匹配不到内容（规则与站点不匹配）
            noResultCount++;
          } else if (error.contains('规则')) {
            configErrorCount++;
          } else {
            noResultCount++;
          }
        }
        onProgress?.call(BatchTestProgress(
          done: done,
          total: testable.length,
          current: source,
          result: record,
        ));
      }
    }

    final workers = List.generate(
      maxConcurrent.clamp(1, testable.isEmpty ? 1 : testable.length),
      (_) => worker(),
    );
    await Future.wait(workers);

    return BatchTestSummary(
      total: testable.length,
      usable: usable,
      unusable: unusable,
      skipped: skipped,
      timeoutCount: timeoutCount,
      networkErrorCount: networkErrorCount,
      noResultCount: noResultCount,
      configErrorCount: configErrorCount,
    );
  }

  Future<BookSourceTestRecord> _testOne(
    BookSource source,
    CancelToken? cancelToken,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await tester
          .testSearch(source, testKeyword, cancelToken: cancelToken)
          .timeout(perSourceTimeout);
      stopwatch.stop();
      return BookSourceTestRecord(
        usable: result.success,
        responseTimeMs: stopwatch.elapsedMilliseconds,
        testedAt: DateTime.now(),
        resultCount: result.resultCount,
        error: result.success ? null : result.message,
      );
    } on TimeoutException {
      stopwatch.stop();
      return BookSourceTestRecord(
        usable: false,
        responseTimeMs: stopwatch.elapsedMilliseconds,
        testedAt: DateTime.now(),
        error: '检测超时（${perSourceTimeout.inSeconds} 秒）',
      );
    } on DioException catch (e) {
      stopwatch.stop();
      return BookSourceTestRecord(
        usable: false,
        responseTimeMs: stopwatch.elapsedMilliseconds,
        testedAt: DateTime.now(),
        error: '请求失败: ${e.type.name}',
      );
    } catch (e) {
      stopwatch.stop();
      return BookSourceTestRecord(
        usable: false,
        responseTimeMs: stopwatch.elapsedMilliseconds,
        testedAt: DateTime.now(),
        error: '检测异常: $e',
      );
    }
  }
}
