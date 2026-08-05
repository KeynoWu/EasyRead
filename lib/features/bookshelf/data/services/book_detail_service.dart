import 'dart:convert';
import 'package:hive/hive.dart';

/// 书籍详情 URL 与替代书源缓存，避免在书架模型中破坏既有 Hive schema。
class BookDetail {
  final String? detailUrl;
  final String? alternativesJson;

  const BookDetail({this.detailUrl, this.alternativesJson});
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
  }) async {
    final box = await _box();
    await box.put(bookId, jsonEncode({
      'detail_url': detailUrl,
      'alternatives_json': alternativesJson,
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
