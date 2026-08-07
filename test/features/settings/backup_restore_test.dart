import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/core/database/hive_init.dart';
import 'package:easy_read/core/data/cookie_jar_service.dart';
import 'package:easy_read/features/bookshelf/data/models/book_model.dart';
import 'package:easy_read/features/bookshelf/data/repositories/bookshelf_repository_impl.dart';
import 'package:easy_read/features/bookshelf/domain/entities/book.dart';
import 'package:easy_read/features/book_source/data/models/book_source_model.dart';
import 'package:easy_read/features/book_source/data/repositories/book_source_repository_impl.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/settings/domain/usecases/backup_restore.dart';

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_backup_test').path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(BookModelAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(BookSourceModelAdapter());
    }
    await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('BackupRestore', () {
    test('backup and restore round-trip preserves typed boxes', () async {
      final repo = BookshelfRepositoryImpl();
      final srcRepo = BookSourceRepositoryImpl();
      await repo.save(Book(
        id: 'b1',
        name: '测试书籍',
        sourceId: 'local',
        group: '正在看',
        lastReadAt: DateTime(2026, 1, 1),
      ));
      await srcRepo.save(const BookSource(
        id: 's1',
        name: '测试书源',
        bookSourceUrl: 'http://example.com',
        rules: {'searchUrl': 'http://example.com/s?q={{key}}'},
      ));

      final backupRestore = BackupRestore(
        bookshelfRepo: repo,
        sourceRepo: srcRepo,
      );
      final json = await backupRestore.buildBackupJson();

      // 模拟数据清空后再恢复（覆盖 _clearBox 对类型化 box 的处理）
      await repo.delete('b1');
      await srcRepo.delete('s1');

      final result = await backupRestore.restoreFromJson(json);
      expect(result, contains('恢复成功'));

      final book = await repo.getById('b1');
      expect(book, isNotNull);
      expect(book!.name, '测试书籍');
      expect(book.group, '正在看');

      final source = await srcRepo.getById('s1');
      expect(source, isNotNull);
      expect(source!.searchUrl, 'http://example.com/s?q={{key}}');
    });

    test('restore should tolerate legacy v1 backup without new fields', () async {
      final repo = BookshelfRepositoryImpl();
      final srcRepo = BookSourceRepositoryImpl();
      final backupRestore = BackupRestore(bookshelfRepo: repo, sourceRepo: srcRepo);

      // v1 备份：仅含 books 与 book_sources
      const legacy = '''
      {
        "version": 1,
        "exported_at": "2026-01-01T00:00:00.000",
        "books": [{"id": "b1", "name": "旧书", "progress": 0.5}],
        "book_sources": []
      }
      ''';
      final result = await backupRestore.restoreFromJson(legacy);
      expect(result, contains('恢复成功'));
      final book = await repo.getById('b1');
      expect(book, isNotNull);
      expect(book!.progress, 0.5);
    });

    test('backup should include string boxes even when not currently open', () async {
      final bookmarkBox = await Hive.openBox<String>('bookmarks');
      await bookmarkBox.put('bookmark-1', jsonEncode({
        'id': 'bookmark-1',
        'book_id': 'b1',
        'chapter_index': 1,
        'page_index': 2,
        'created_at': '2026-01-01T00:00:00.000',
      }));
      await bookmarkBox.close();

      final backupRestore = BackupRestore(
        bookshelfRepo: BookshelfRepositoryImpl(),
        sourceRepo: BookSourceRepositoryImpl(),
      );
      final json = await backupRestore.buildBackupJson();
      final data = jsonDecode(json) as Map<String, dynamic>;
      expect(data['bookmarks'], containsPair('bookmark-1', isA<String>()));
    });

    test('backup and restore preserves cookie jar', () async {
      final jar = CookieJarService();
      await jar.set('s1', 'session=abc');
      final backupRestore = BackupRestore(
        bookshelfRepo: BookshelfRepositoryImpl(),
        sourceRepo: BookSourceRepositoryImpl(),
      );
      final json = await backupRestore.buildBackupJson();
      final data = jsonDecode(json) as Map<String, dynamic>;
      expect(data['cookie_jar'], containsPair('s1', 'session=abc'));

      await jar.remove('s1');
      final result = await backupRestore.restoreFromJson(json);
      expect(result, contains('恢复成功'));
      expect(await jar.get('s1'), 'session=abc');
    });
  });
}
