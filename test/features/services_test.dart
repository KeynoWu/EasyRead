import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/features/search/data/services/search_history_service.dart';
import 'package:easy_read/features/settings/domain/usecases/reading_stats_service.dart';
import 'package:easy_read/features/reader/domain/entities/bookmark.dart';
import 'package:easy_read/features/reader/domain/entities/reading_note.dart';

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_test').path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('SearchHistoryService', () {
    test('should add and retrieve keywords (newest first)', () async {
      final service = SearchHistoryService();
      await service.add('斗破苍穹');
      await service.add('凡人修仙传');
      await service.add('斗破苍穹'); // 重复去重

      final recent = await service.getRecent();
      expect(recent.length, 2);
      expect(recent[0], '斗破苍穹'); // 最新在前
      expect(recent[1], '凡人修仙传');
    });

    test('should clear history', () async {
      final service = SearchHistoryService();
      await service.add('测试');
      await service.clear();
      expect(await service.getRecent(), isEmpty);
    });
  });

  group('ReadingStatsService', () {
    test('should record session and summarize', () async {
      final service = ReadingStatsService();
      await service.recordSession(120);
      await service.recordSession(60);

      final summary = await service.getSummary();
      expect(summary.totalSeconds, greaterThanOrEqualTo(180));
      expect(summary.totalDays, greaterThanOrEqualTo(1));
    });
  });

  group('Bookmark', () {
    test('should create bookmark with fields', () {
      final bookmark = Bookmark(
        id: 'b1',
        bookId: 'book1',
        chapterIndex: 2,
        pageIndex: 5,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(bookmark.bookId, 'book1');
      expect(bookmark.chapterIndex, 2);
      expect(bookmark.pageIndex, 5);
    });
  });

  group('ReadingNote', () {
    test('should create note with fields', () {
      final note = ReadingNote(
        id: 'n1',
        bookId: 'book1',
        chapterIndex: 1,
        text: '这里写得真好',
        createdAt: DateTime(2026, 1, 1),
      );
      expect(note.text, '这里写得真好');
      expect(note.chapterIndex, 1);
    });
  });
}
