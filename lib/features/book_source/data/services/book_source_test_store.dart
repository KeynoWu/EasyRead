import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/book_source_test_record.dart';

/// 书源检测结果存储：独立 JSON 字符串盒（key = 书源 id），
/// 与书源模型解耦，避免改动加密盒格式。
class BookSourceTestStore {
  static const String boxName = 'book_source_tests';

  Future<Box<String>> _box() => Hive.openBox<String>(boxName);

  Future<void> save(String sourceId, BookSourceTestRecord record) async {
    final box = await _box();
    await box.put(sourceId, jsonEncode(record.toJson()));
  }

  Future<BookSourceTestRecord?> get(String sourceId) async {
    final box = await _box();
    final raw = box.get(sourceId);
    if (raw == null || raw.isEmpty) return null;
    try {
      return BookSourceTestRecord.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, BookSourceTestRecord>> getAll() async {
    final box = await _box();
    final result = <String, BookSourceTestRecord>{};
    for (final entry in box.toMap().entries) {
      final raw = entry.value;
      if (raw.isEmpty) continue;
      try {
        result[entry.key.toString()] = BookSourceTestRecord.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // 损坏条目跳过
      }
    }
    return result;
  }

  Future<void> remove(String sourceId) async {
    final box = await _box();
    await box.delete(sourceId);
  }

  Future<void> clear() async {
    final box = await _box();
    await box.clear();
  }
}
