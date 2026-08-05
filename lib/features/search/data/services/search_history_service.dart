import 'dart:convert';
import 'package:hive/hive.dart';

/// 搜索历史服务
class SearchHistoryService {
  static const String _boxName = 'search_history';
  static const int _maxEntries = 20;

  Box<String>? _cachedBox;

  /// 写操作串行队列：add() 的读-改-写必须按序执行，
  /// 并发调用（防抖与提交可在同一时刻触发）会互相覆盖导致丢记录
  Future<void> _queue = Future.value();

  Future<Box<String>> _box() async =>
      _cachedBox ??= await Hive.openBox<String>(_boxName);

  /// 获取最近搜索关键词（新→旧）
  Future<List<String>> getRecent() async {
    final box = await _box();
    final list = box.get('keywords');
    if (list == null) return [];
    try {
      final decoded = jsonDecode(list) as List;
      return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存搜索关键词（去重，最新在前）。经内部队列串行执行，
  /// 避免并发 add 的读-改-写竞态丢记录。
  Future<void> add(String keyword) {
    final task = _queue.then((_) => _addNow(keyword));
    // 吞掉错误继续队列，但调用方仍能感知本次失败
    _queue = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _addNow(String keyword) async {
    final box = await _box();
    final recent = await getRecent();
    recent.remove(keyword);
    recent.insert(0, keyword);
    if (recent.length > _maxEntries) {
      recent.removeRange(_maxEntries, recent.length);
    }
    await box.put('keywords', jsonEncode(recent));
  }

  /// 删除单条搜索历史
  Future<void> remove(String keyword) {
    final task = _queue.then((_) => _removeNow(keyword));
    _queue = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<void> _removeNow(String keyword) async {
    final box = await _box();
    final recent = await getRecent();
    if (recent.remove(keyword)) {
      await box.put('keywords', jsonEncode(recent));
    }
  }

  /// 清空历史
  Future<void> clear() async {
    final box = await _box();
    await box.put('keywords', jsonEncode([]));
  }
}
