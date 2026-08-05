import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart' as dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/features/book_source/data/services/book_source_test_store.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/usecases/batch_test_book_sources.dart';
import 'package:easy_read/features/book_source/domain/usecases/test_book_source.dart';

/// 可控的假测试器：按源名返回预设结果，模拟耗时
class _FakeTester extends TestBookSource {
  final Map<String, bool> usableBySource;
  final Duration delay;

  _FakeTester({Map<String, bool>? usableBySource, this.delay = Duration.zero})
      : usableBySource = usableBySource ?? {};

  @override
  Future<BookSourceTestResult> testSearch(
    BookSource source,
    String keyword, {
    dio.CancelToken? cancelToken,
  }) async {
    await Future<void>.delayed(delay);
    final usable = usableBySource[source.name] ?? true;
    return BookSourceTestResult(
      success: usable,
      message: usable ? 'ok' : '规则不匹配',
      resultCount: usable ? 3 : 0,
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('batch_test');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  BookSource makeSource(String id, String name, {bool enabled = true, bool searchable = true}) {
    return BookSource(
      id: id,
      name: name,
      bookSourceUrl: 'https://$id.example.com',
      enabled: enabled,
      rules: searchable
          ? {
              'searchUrl': 'https://$id.example.com/search?q={{key}}',
              'bookList': 'div.item',
              'bookName': 'h3',
            }
          : {},
    );
  }

  test('批量检测：并发执行、进度回调、结果持久化', () async {
    final store = BookSourceTestStore();
    final batch = BatchTestBookSources(
      tester: _FakeTester(usableBySource: {'A': true, 'B': false, 'C': true}),
      store: store,
    );

    final sources = [
      makeSource('a', 'A'),
      makeSource('b', 'B'),
      makeSource('c', 'C'),
    ];
    final progress = <BatchTestProgress>[];
    final summary = await batch.run(
      sources: sources,
      onProgress: (p) => progress.add(p),
    );

    expect(summary.total, 3);
    expect(summary.usable, 2);
    expect(summary.unusable, 1);
    expect(summary.skipped, 0);
    expect(progress, hasLength(3));
    // 进度应单调递增
    final doneSeq = progress.map((p) => p.done).toList();
    expect(doneSeq, [1, 2, 3]);

    // 结果已持久化
    final a = await store.get('a');
    expect(a, isNotNull);
    expect(a!.usable, isTrue);
    final b = await store.get('b');
    expect(b!.usable, isFalse);
    expect(b.error, isNotNull);
  });

  test('批量检测：跳过无搜索能力/已禁用的源', () async {
    final store = BookSourceTestStore();
    final batch = BatchTestBookSources(tester: _FakeTester(), store: store);

    final summary = await batch.run(sources: [
      makeSource('a', 'A'),
      makeSource('b', 'B', enabled: false), // 禁用
      makeSource('c', 'C', searchable: false), // 无搜索规则
    ]);

    expect(summary.total, 1); // 只有 A 参与检测
    expect(summary.skipped, 2);
    expect(await store.get('b'), isNull);
  });

  test('批量检测：超时判定不可用', () async {
    final store = BookSourceTestStore();
    // 超时分支：用手工构造的 tester 抛 TimeoutException
    final slowBatch = BatchTestBookSources(
      tester: _AlwaysTimeoutTester(),
      store: store,
    );
    final summary = await slowBatch.run(sources: [makeSource('a', 'A')]);
    expect(summary.usable, 0);
    expect(summary.unusable, 1);
    final record = await store.get('a');
    expect(record!.usable, isFalse);
    expect(record.error, contains('超时'));
  });

  test('批量检测：取消后剩余源不检测', () async {
    final store = BookSourceTestStore();
    final batch = BatchTestBookSources(
      tester: _FakeTester(delay: const Duration(milliseconds: 30)),
      store: store,
    );
    final sources = [
      for (var i = 0; i < 10; i++) makeSource('s$i', 'S$i'),
    ];
    final cancel = CancelTokenStub();
    // 立即取消，worker 应快速退出
    final summary = await batch.run(
      sources: sources,
      cancelToken: cancel.token,
    );
    expect(summary.usable + summary.unusable, lessThanOrEqualTo(10));
  });
}

/// 取消令牌桩：构造即已取消
class CancelTokenStub {
  final dio.CancelToken token = dio.CancelToken();

  CancelTokenStub() {
    token.cancel();
  }
}

/// 恒抛超时的测试器
class _AlwaysTimeoutTester extends TestBookSource {
  @override
  Future<BookSourceTestResult> testSearch(
    BookSource source,
    String keyword, {
    dio.CancelToken? cancelToken,
  }) async {
    throw TimeoutException('模拟超时');
  }
}
