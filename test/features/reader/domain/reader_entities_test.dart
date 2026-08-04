import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';

void main() {
  group('Chapter', () {
    test('should create chapter with correct fields', () {
      final chapter = Chapter(
        id: 'ch1',
        bookId: 'book1',
        title: '第一章',
        content: '内容',
        index: 0,
        sourceId: 'source1',
        cachedAt: DateTime(2026, 1, 1),
      );
      expect(chapter.id, 'ch1');
      expect(chapter.bookId, 'book1');
      expect(chapter.title, '第一章');
      expect(chapter.content, '内容');
      expect(chapter.index, 0);
      expect(chapter.sourceId, 'source1');
    });

    test('copyWith should preserve unchanged fields', () {
      final chapter = Chapter(
        id: 'ch1',
        bookId: 'book1',
        title: '第一章',
        content: '内容',
        index: 0,
      );
      final updated = chapter.copyWith(title: '新标题', index: 1);
      expect(updated.id, 'ch1');
      expect(updated.bookId, 'book1');
      expect(updated.title, '新标题');
      expect(updated.index, 1);
      expect(updated.content, '内容');
    });
  });

  group('ReadingProgress', () {
    test('should create progress with defaults', () {
      final progress = ReadingProgress(
        bookId: 'book1',
        updatedAt: DateTime(2026, 1, 1),
      );
      expect(progress.chapterIndex, 0);
      expect(progress.paragraphOffset, 0);
      expect(progress.scrollOffset, 0.0);
      expect(progress.pageIndex, 0);
    });

    test('copyWith should update fields', () {
      final progress = ReadingProgress(
        bookId: 'book1',
        updatedAt: DateTime(2026, 1, 1),
      );
      final updated = progress.copyWith(chapterIndex: 5, pageIndex: 3);
      expect(updated.chapterIndex, 5);
      expect(updated.pageIndex, 3);
      expect(updated.bookId, 'book1');
    });
  });
}
