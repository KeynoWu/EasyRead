import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/features/search/data/services/search_history_service.dart';
import 'package:easy_read/features/settings/domain/usecases/reading_stats_service.dart';
import 'package:easy_read/features/reader/data/services/bookmark_service.dart';
import 'package:easy_read/features/reader/data/services/note_service.dart';
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

  group('BookmarkService', () {
    test('should isolate bookmarks by book and remove by id', () async {
      final service = BookmarkService();
      await service.add(Bookmark(
        id: 'b1',
        bookId: 'book1',
        chapterIndex: 1,
        pageIndex: 2,
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(Bookmark(
        id: 'b2',
        bookId: 'book2',
        chapterIndex: 1,
        pageIndex: 2,
        createdAt: DateTime(2026, 1, 1),
      ));

      expect((await service.getBookmarks('book1')).length, 1);
      await service.remove('book1', 'b1');
      expect(await service.getBookmarks('book1'), isEmpty);
      expect((await service.getBookmarks('book2')).length, 1);
    });

    test('should remove only the bookmark from the requested book', () async {
      final service = BookmarkService();
      await service.add(Bookmark(
        id: 'same-id',
        bookId: 'book1',
        chapterIndex: 1,
        pageIndex: 2,
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(Bookmark(
        id: 'same-id',
        bookId: 'book2',
        chapterIndex: 1,
        pageIndex: 2,
        createdAt: DateTime(2026, 1, 1),
      ));

      await service.remove('book1', 'same-id');
      expect(await service.getBookmarks('book1'), isEmpty);
      expect((await service.getBookmarks('book2')).length, 1);
    });

    test('removeAllForBook 删除某本书全部书签', () async {
      final service = BookmarkService();
      await service.add(Bookmark(
        id: 'b1',
        bookId: 'book1',
        chapterIndex: 1,
        pageIndex: 2,
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(Bookmark(
        id: 'b2',
        bookId: 'book1',
        chapterIndex: 2,
        pageIndex: 3,
        createdAt: DateTime(2026, 1, 2),
      ));
      await service.add(Bookmark(
        id: 'b3',
        bookId: 'book2',
        chapterIndex: 1,
        pageIndex: 1,
        createdAt: DateTime(2026, 1, 3),
      ));

      await service.removeAllForBook('book1');
      expect(await service.getBookmarks('book1'), isEmpty);
      expect((await service.getBookmarks('book2')).length, 1);
    });

    test('should list all bookmarks and remove by global id', () async {
      final service = BookmarkService();
      await service.add(Bookmark(
        id: 'g1',
        bookId: 'book1',
        chapterIndex: 1,
        pageIndex: 2,
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(Bookmark(
        id: 'g2',
        bookId: 'book2',
        chapterIndex: 3,
        pageIndex: 4,
        createdAt: DateTime(2026, 1, 2),
      ));

      final all = await service.getAll();
      expect(all.length, 2);
      await service.removeById('g1');
      expect((await service.getAll()).single.id, 'g2');
    });
  });

  group('NoteService', () {
    test('should isolate notes by book and remove by id', () async {
      final service = NoteService();
      await service.add(ReadingNote(
        id: 'n1',
        bookId: 'book1',
        chapterIndex: 1,
        text: '笔记1',
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(ReadingNote(
        id: 'n2',
        bookId: 'book2',
        chapterIndex: 1,
        text: '笔记2',
        createdAt: DateTime(2026, 1, 1),
      ));

      expect((await service.getNotes('book1')).length, 1);
      await service.remove('book1', 'n1');
      expect(await service.getNotes('book1'), isEmpty);
      expect((await service.getNotes('book2')).length, 1);
    });

    test('should remove only the note from the requested book', () async {
      final service = NoteService();
      await service.add(ReadingNote(
        id: 'same-id',
        bookId: 'book1',
        chapterIndex: 1,
        text: 'book1 note',
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(ReadingNote(
        id: 'same-id',
        bookId: 'book2',
        chapterIndex: 1,
        text: 'book2 note',
        createdAt: DateTime(2026, 1, 1),
      ));

      await service.remove('book1', 'same-id');
      expect(await service.getNotes('book1'), isEmpty);
      expect((await service.getNotes('book2')).length, 1);
    });

    test('removeAllForBook 删除某本书全部笔记', () async {
      final service = NoteService();
      await service.add(ReadingNote(
        id: 'n1',
        bookId: 'book1',
        chapterIndex: 1,
        text: '笔记1',
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(ReadingNote(
        id: 'n2',
        bookId: 'book1',
        chapterIndex: 2,
        text: '笔记2',
        createdAt: DateTime(2026, 1, 2),
      ));
      await service.add(ReadingNote(
        id: 'n3',
        bookId: 'book2',
        chapterIndex: 1,
        text: '笔记3',
        createdAt: DateTime(2026, 1, 3),
      ));

      await service.removeAllForBook('book1');
      expect(await service.getNotes('book1'), isEmpty);
      expect((await service.getNotes('book2')).length, 1);
    });

    test('should list all notes and remove by global id', () async {
      final service = NoteService();
      await service.add(ReadingNote(
        id: 'g1',
        bookId: 'book1',
        chapterIndex: 1,
        text: '笔记1',
        createdAt: DateTime(2026, 1, 1),
      ));
      await service.add(ReadingNote(
        id: 'g2',
        bookId: 'book2',
        chapterIndex: 2,
        text: '笔记2',
        createdAt: DateTime(2026, 1, 2),
      ));

      expect((await service.getAll()).length, 2);
      await service.removeById('g1');
      expect((await service.getAll()).single.text, '笔记2');
    });
  });
}
