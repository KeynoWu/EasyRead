import 'dart:async';
import 'package:dio/dio.dart';

/// 请求频率控制 — 每个书源独立限流（Legado concurrentRate 语义）。
///
/// 源配置通过请求 extra['concurrent_rate'] 传入，两种格式：
/// - `N/M`：M 毫秒窗口内最多 N 次请求；**不串行**——窗口未满时 N 个请求
///   可同时在途，满窗后才等待窗口重置（对齐 Legado ConcurrentRateLimiter
///   固定窗口语义；记录初值 1 导致实际放行 N+1 次，此处同样放行到 N+1）。
/// - 单数字：相邻请求最小间隔（毫秒），串行排队保证节拍（以放行时刻为
///   节拍起点，间隔语义本身要求逐个放行）。
/// 未配置（null）时回退 [minIntervalMs] 全局默认间隔；
/// 显式 `'0'` 视为不限制（调用方 BookSource.concurrentRate 已过滤）。
class RateLimitInterceptor extends Interceptor {
  RateLimitInterceptor({this.minIntervalMs = 1000});

  final int minIntervalMs;

  /// 每源串行链（仅间隔模式使用）：同源请求排队，避免并发 burst
  /// 同时醒来再一起等待
  final Map<String, Future<void>> _chain = {};

  /// 每源窗口记录：`(windowStart, count)`
  final Map<String, _Window> _windows = {};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final sourceKey = options.extra['source_id'] as String? ?? 'default';
    final rate = options.extra['concurrent_rate'] as String?;
    if (_isWindowMode(rate)) {
      // N/M 窗口模式：不串行，每请求独立判窗
      final waitMs = _waitByWindow(sourceKey, rate!);
      if (waitMs > 0) {
        Future<void>.delayed(Duration(milliseconds: waitMs)).then((_) {
          _markReleased(sourceKey, rate);
          handler.next(options);
        });
      } else {
        _markReleased(sourceKey, rate);
        handler.next(options);
      }
      return;
    }
    // 间隔模式（含回退全局默认）：串行链
    final prev = _chain[sourceKey] ?? Future.value();
    // catchError 防止链上任一环节异常导致后续请求永久挂起
    final task = prev.catchError((_) {}).then((_) async {
      final waitMs = _computeIntervalWaitMs(sourceKey, rate);
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
      // 以实际放行时刻提交窗口状态（间隔模式以此为新节拍起点）
      _markReleased(sourceKey, rate);
      handler.next(options);
    });
    _chain[sourceKey] = task;
  }

  bool _isWindowMode(String? rate) {
    if (rate == null || rate.isEmpty) return false;
    final slash = rate.indexOf('/');
    if (slash <= 0) return false;
    return int.tryParse(rate.substring(0, slash)) != null &&
        int.tryParse(rate.substring(slash + 1)) != null;
  }

  /// 间隔模式等待计算（未配置/单数字/0）
  int _computeIntervalWaitMs(String sourceKey, String? rate) {
    if (rate == null || rate.isEmpty || rate == '0') {
      return _waitByInterval(sourceKey, minIntervalMs);
    }
    final interval = int.tryParse(rate);
    if (interval == null || interval <= 0) return 0;
    return _waitByInterval(sourceKey, interval);
  }

  /// 放行后提交窗口状态,并惰性清理过期窗口
  /// (书源删除后避免 Map 无界残留;链尾 onRequest 覆盖写自然收敛,无需清)
  void _markReleased(String sourceKey, String? rate) {
    final now = DateTime.now();
    final slash = (rate ?? '').indexOf('/');
    if (slash > 0 && int.tryParse(rate!.substring(0, slash)) != null &&
        int.tryParse(rate.substring(slash + 1)) != null) {
      // 窗口模式:过期/新开窗口则重置,否则计数 +1
      final m = int.parse(rate.substring(slash + 1));
      final window = _windows[sourceKey];
      if (window == null || now.difference(window.start).inMilliseconds >= m) {
        _windows[sourceKey] = _Window(now, 1);
      } else {
        window.count += 1;
      }
    } else {
      // 间隔模式(含回退全局间隔):以放行时刻为新节拍起点
      final interval = rate == null || rate.isEmpty || rate == '0'
          ? minIntervalMs
          : (int.tryParse(rate) ?? 0);
      if (interval > 0) {
        _windows[sourceKey] = _Window(now, 1);
      }
    }
    _gc();
  }

  /// 惰性垃圾回收:清过期窗口(超过 10 分钟未活动)
  void _gc() {
    final now = DateTime.now();
    _windows.removeWhere(
        (_, w) => now.difference(w.start).inMilliseconds > 10 * 60 * 1000);
  }

  /// 间隔模式：距上次放行不足 interval 则补足
  int _waitByInterval(String sourceKey, int intervalMs) {
    if (intervalMs <= 0) return 0;
    final window = _windows[sourceKey];
    if (window == null) return 0;
    final elapsed = DateTime.now().difference(window.start).inMilliseconds;
    return elapsed < intervalMs ? intervalMs - elapsed : 0;
  }

  /// 窗口模式（N/M）：窗口未满（count <= N，对齐 Legado 放行 N+1 次）
  /// 立即放行；已满等待到窗口重置
  int _waitByWindow(String sourceKey, String rate) {
    final slash = rate.indexOf('/');
    final n = int.tryParse(rate.substring(0, slash));
    final m = int.tryParse(rate.substring(slash + 1));
    if (n == null || m == null || n <= 0 || m <= 0) return 0;
    final now = DateTime.now();
    final window = _windows[sourceKey];
    if (window == null || now.difference(window.start).inMilliseconds >= m) {
      return 0;
    }
    if (window.count > n) {
      return m - now.difference(window.start).inMilliseconds;
    }
    return 0;
  }
}

class _Window {
  _Window(this.start, this.count);

  DateTime start;
  int count;
}
