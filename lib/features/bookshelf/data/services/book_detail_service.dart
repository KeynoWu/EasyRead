import 'dart:convert';
import 'package:hive/hive.dart';

/// 书籍详情 URL 与替代书源缓存，避免在书架模型中破坏既有 Hive schema。
class BookDetail {
  final String? detailUrl;
  final String? alternativesJson;
  final String? variablesJson;

  const BookDetail({
    this.detailUrl,
    this.alternativesJson,
    this.variablesJson,
  });

  /// 将书源 `@put:` 变量 JSON 解码为变量表（供目录/正文 URL 的 `@get:` 使用）。
  static Map<String, String> decodeVariables(String? json) {
    if (json == null || json.isEmpty) return const {};
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value?.toString() ?? '',
        };
      }
    } catch (_) {}
    return const {};
  }
}

class BookDetailService {
  static const String _boxName = 'book_details';

  Box<String>? _cachedBox;

  Future<Box<String>> _box() async =>
      _cachedBox ??= await Hive.openBox<String>(_boxName);

  Future<void> save(
    String bookId, {
    String? detailUrl,
    String? alternativesJson,
    String? variablesJson,
  }) async {
    final box = await _box();
    await box.put(bookId, jsonEncode({
      'detail_url': detailUrl,
      'alternatives_json': alternativesJson,
      'variables_json': variablesJson,
    }));
  }

  Future<BookDetail?> get(String bookId) async {
    final box = await _box();
    final raw = box.get(bookId);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return BookDetail(
        detailUrl: map['detail_url']?.toString(),
        alternativesJson: map['alternatives_json']?.toString(),
        variablesJson: map['variables_json']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String bookId) async {
    final box = await _box();
    await box.delete(bookId);
  }
}
