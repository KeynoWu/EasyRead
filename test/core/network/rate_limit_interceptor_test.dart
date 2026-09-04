import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_read/core/network/interceptors/rate_limit_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 返回固定 200 响应的本地适配器（无真实网络）
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Dio makeDio(RateLimitInterceptor interceptor) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    dio.httpClientAdapter = _StubAdapter();
    dio.interceptors.add(interceptor);
    return dio;
  }

  /// 顺序发起 count 个同源请求，返回放行时刻
  Future<List<DateTime>> stamp(
    Dio dio, {
    int count = 3,
    required String rate,
    String sourceId = 'src',
  }) async {
    final stamps = <DateTime>[];
    for (var i = 0; i < count; i++) {
      await dio.get('https://example.invalid/x',
          options: Options(
            extra: {
              'source_id': sourceId,
              'concurrent_rate': rate,
            },
          ));
      // 记录放行完成时刻（拦截器等待已在 dio.get 内结束）
      stamps.add(DateTime.now());
    }
    return stamps;
  }

  int gapMs(List<DateTime> list, int a, int b) =>
      list[b].difference(list[a]).inMilliseconds;

  group('RateLimitInterceptor', () {
    test('间隔模式：相邻请求补足到间隔', () async {
      final stamps = await stamp(makeDio(RateLimitInterceptor()),
          count: 3, rate: '300');
      expect(gapMs(stamps, 0, 1), greaterThanOrEqualTo(280));
      expect(gapMs(stamps, 1, 2), greaterThanOrEqualTo(280));
    });

    test('滑窗模式 N/M：窗口内 N+1 次放行（Legado freq 初值 1），超出等待重置', () async {
      // 3/300：对齐 Legado ConcurrentRateLimiter——首请求建记录不计数，
      // 实际同窗放行 N+1=4 次；第 5 次需等到窗口重置
      final stamps =
          await stamp(makeDio(RateLimitInterceptor()), count: 5, rate: '3/300');
      // 前 4 次同窗放行（几乎无等待）
      expect(gapMs(stamps, 0, 3), lessThan(250));
      // 第 5 次等待窗口重置：距第 1 次约 >= 300ms
      expect(stamps[4].difference(stamps[0]).inMilliseconds,
          greaterThanOrEqualTo(290));
    });

    test('滑窗模式窗口过后计数归零', () async {
      final client = makeDio(RateLimitInterceptor());
      await stamp(client, count: 2, rate: '2/100');
      // 跨过 100ms 窗口
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final t0 = DateTime.now();
      final b = await stamp(client, count: 2, rate: '2/100');
      // 新窗口首请求不应再等待到窗口重置（100ms 量级）
      expect(b[0].difference(t0).inMilliseconds, lessThan(80));
    });

    test('不同源互不影响', () async {
      final client = makeDio(RateLimitInterceptor());
      await client.get('https://example.invalid/a',
          options: Options(extra: {
            'source_id': 's1',
            'concurrent_rate': '500',
          }));
      // s1 已占用一个 500ms 间隔窗口；s2 未配置源级限制，
      // 走全局默认间隔且首请求无等待 → 应立即放行
      final s2Start = DateTime.now();
      await client.get('https://example.invalid/b',
          options: Options(extra: {'source_id': 's2'}));
      final s2Latency = DateTime.now().difference(s2Start).inMilliseconds;
      // s2 应无显著等待（s1 的 500ms 窗口不影响 s2）
      expect(s2Latency, lessThan(400));
    });

    test('未配置源级限制回退全局默认间隔', () async {
      final client = makeDio(RateLimitInterceptor(minIntervalMs: 250));
      final stamps = <DateTime>[];
      for (var i = 0; i < 2; i++) {
        await client.get('https://example.invalid/x',
            options: Options(extra: {'source_id': 'src'}));
        stamps.add(DateTime.now());
      }
      expect(gapMs(stamps, 0, 1), greaterThanOrEqualTo(230));
    });

    test('非法格式按不限制处理', () async {
      final dio = makeDio(RateLimitInterceptor(minIntervalMs: 0));
      final stamps = <DateTime>[];
      for (var i = 0; i < 3; i++) {
        await dio.get('https://example.invalid/x',
            options: Options(extra: {
              'source_id': 'src',
              'concurrent_rate': 'abc',
            }));
        stamps.add(DateTime.now());
      }
      // 全部立即放行
      expect(gapMs(stamps, 0, 2), lessThan(200));
    });
  });
}
