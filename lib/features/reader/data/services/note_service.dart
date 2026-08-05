import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/reading_note.dart';

/// 阅读笔记服务 — Hive 持久化
class NoteService {
  static const String _boxName = 'reading_notes';

  Box<String>? _cachedBox;

  Future<Box<String>> _box() async =>
      _cachedBox ??= await Hive.openBox<String>(_boxName);

  /// 获取某本书的所有笔记（按创建时间倒序）
  Future<List<ReadingNote>> getNotes(String bookId) async {
    final box = await _box();
    final notes = <ReadingNote>[];
    for (final entry in box.toMap().entries) {
      final key = entry.key.toString();
      if (key.contains('|') && !key.startsWith('$bookId|')) {
        continue;
      }
      try {
        final map = jsonDecode(entry.value) as Map<String, dynamic>;
        if (map['book_id'] == bookId) {
          notes.add(ReadingNote(
            id: map['id']?.toString() ?? '',
            bookId: map['book_id']?.toString() ?? bookId,
            chapterIndex: (map['chapter_index'] as num?)?.toInt() ?? 0,
            text: map['text']?.toString() ?? '',
            createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ?? DateTime.now(),
          ));
        }
      } catch (_) {
        // 跳过损坏数据
      }
    }
    notes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return notes;
  }

  /// 添加笔记
  Future<void> add(ReadingNote note) async {
    final box = await _box();
    await box.put('${note.bookId}|${note.id}', jsonEncode({
      'id': note.id,
      'book_id': note.bookId,
      'chapter_index': note.chapterIndex,
      'text': note.text,
      'created_at': note.createdAt.toIso8601String(),
    }));
  }

  /// 删除指定书籍下的笔记
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
}
