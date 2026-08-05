import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/bookmark.dart';

/// 书签服务 — Hive 持久化
class BookmarkService {
  static const String _boxName = 'bookmarks';

  Box<String>? _cachedBox;

  Future<Box<String>> _box() async =>
      _cachedBox ??= await Hive.openBox<String>(_boxName);

  /// 获取某本书的所有书签（按创建时间倒序）
  Future<List<Bookmark>> getBookmarks(String bookId) async {
    final box = await _box();
    final bookmarks = <Bookmark>[];
    for (final entry in box.toMap().entries) {
      final key = entry.key.toString();
      if (key.contains('|') && !key.startsWith('$bookId|')) {
        continue;
      }
      try {
        final map = jsonDecode(entry.value) as Map<String, dynamic>;
        if (map['book_id'] == bookId) {
          bookmarks.add(Bookmark(
            id: map['id']?.toString() ?? '',
            bookId: map['book_id']?.toString() ?? bookId,
            chapterIndex: (map['chapter_index'] as num?)?.toInt() ?? 0,
            pageIndex: (map['page_index'] as num?)?.toInt() ?? 0,
            createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ?? DateTime.now(),
          ));
        }
      } catch (_) {
        // 跳过损坏数据
      }
    }
    bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return bookmarks;
  }

  /// 添加书签
  Future<void> add(Bookmark bookmark) async {
    final box = await _box();
    await box.put('${bookmark.bookId}|${bookmark.id}', jsonEncode({
      'id': bookmark.id,
      'book_id': bookmark.bookId,
      'chapter_index': bookmark.chapterIndex,
      'page_index': bookmark.pageIndex,
      'created_at': bookmark.createdAt.toIso8601String(),
    }));
  }

  /// 删除指定书籍下的书签
  Future<void> remove(String bookId, String id) async {
    final box = await _box();
    String? key;
    if (box.containsKey('$bookId|$id')) {
      key = '$bookId|$id';
    } else {
      for (final candidate in box.keys) {
        if (candidate.toString() == id) {
          final raw = box.get(candidate);
          if (raw == null) continue;
          try {
            final map = jsonDecode(raw) as Map<String, dynamic>;
            if (map['book_id'] == bookId) {
              key = candidate.toString();
              break;
            }
          } catch (_) {
            // 跳过损坏数据
          }
        }
      }
    }
    if (key == null) return;
    await box.delete(key);
  }

  /// 检查某位置是否已有书签
  Future<bool> exists(String bookId, int chapterIndex, int pageIndex) async {
    final bookmarks = await getBookmarks(bookId);
    return bookmarks.any((b) => b.chapterIndex == chapterIndex && b.pageIndex == pageIndex);
  }
}
