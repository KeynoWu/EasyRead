import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';

void main() {
  group('ChapterModel', () {
    test('should convert to and from entity', () {
      final chapter = Chapter(
        id: 'ch1',
        bookId: 'book1',
        title: '第一章',
        content: '内容',
        index: 0,
        sourceId: 'source1',
        cachedAt: DateTime(2026, 1, 1),
      );
      final model = ChapterModel.fromEntity(chapter);
      expect(model.id, 'ch1');
      expect(model.bookId, 'book1');
      expect(model.title, '第一章');

      final entity = model.toEntity();
      expect(entity.id, chapter.id);
      expect(entity.title, chapter.title);
      expect(entity.content, chapter.content);
    });
  });

  group('ReadingProgressModel', () {
    test('should convert to and from entity', () {
      final progress = ReadingProgress(
        bookId: 'book1',
        chapterIndex: 5,
        pageIndex: 3,
        updatedAt: DateTime(2026, 1, 1),
      );
      final model = ReadingProgressModel.fromEntity(progress);
      expect(model.bookId, 'book1');
      expect(model.chapterIndex, 5);

      final entity = model.toEntity();
      expect(entity.bookId, progress.bookId);
      expect(entity.chapterIndex, progress.chapterIndex);
      expect(entity.pageIndex, progress.pageIndex);
    });
  });
}
