import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../../book_source/domain/entities/book_source.dart';
import '../../../book_source/domain/repositories/book_source_repository.dart';
import '../../../bookshelf/domain/entities/book.dart';
import '../../../bookshelf/domain/repositories/bookshelf_repository.dart';
import '../../../reader/domain/repositories/reader_repository.dart';

/// 备份与恢复
class BackupRestore {
  final BookshelfRepository bookshelfRepo;
  final BookSourceRepository sourceRepo;
  final ReaderRepository readerRepo;

  BackupRestore({
    required this.bookshelfRepo,
    required this.sourceRepo,
    required this.readerRepo,
  });

  /// 生成备份 JSON 字符串
  Future<String> buildBackupJson() async {
    final books = await bookshelfRepo.getAll();
    final sources = await sourceRepo.getAll();

    final backup = {
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'books': books.map((b) => {
        'id': b.id,
        'name': b.name,
        'author': b.author,
        'cover_url': b.coverUrl,
        'source_id': b.sourceId,
        'last_chapter': b.lastChapter,
        'progress': b.progress,
        'group': b.group,
        'last_read_at': b.lastReadAt.toIso8601String(),
      }).toList(),
      'book_sources': sources.map((s) => {
        'id': s.id,
        'name': s.name,
        'book_source_url': s.bookSourceUrl,
        'book_source_group': s.bookSourceGroup,
        'enabled': s.enabled,
        'rules': s.rules,
      }).toList(),
    };
    return jsonEncode(backup);
  }

  /// 从 JSON 字符串恢复
  Future<String?> restoreFromJson(String content) async {
    try {
      final data = jsonDecode(content) as Map<String, dynamic>;

      final books = (data['books'] as List? ?? []);
      for (final item in books) {
        final map = item as Map<String, dynamic>;
        await bookshelfRepo.save(Book(
          id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name: map['name']?.toString() ?? '未命名',
          author: map['author']?.toString(),
          coverUrl: map['cover_url']?.toString(),
          sourceId: map['source_id']?.toString(),
          lastChapter: map['last_chapter']?.toString(),
          progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
          group: map['group']?.toString(),
          lastReadAt: DateTime.tryParse(map['last_read_at']?.toString() ?? '') ?? DateTime.now(),
        ));
      }

      final sources = (data['book_sources'] as List? ?? []);
      for (final item in sources) {
        final map = item as Map<String, dynamic>;
        await sourceRepo.save(BookSource(
          id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name: map['name']?.toString() ?? '未命名书源',
          bookSourceUrl: map['book_source_url']?.toString(),
          bookSourceGroup: map['book_source_group']?.toString(),
          enabled: map['enabled'] as bool? ?? true,
          rules: Map<String, dynamic>.from(map['rules'] as Map? ?? {}),
        ));
      }

      return '恢复成功：${books.length} 本书，${sources.length} 个书源';
    } catch (e) {
      return '恢复失败: $e';
    }
  }

  /// 导出备份到文件
  Future<String?> exportBackup() async {
    try {
      final books = await bookshelfRepo.getAll();
      final sources = await sourceRepo.getAll();

      final backup = {
        'version': 1,
        'exported_at': DateTime.now().toIso8601String(),
        'books': books.map((b) => {
          'id': b.id,
          'name': b.name,
          'author': b.author,
          'cover_url': b.coverUrl,
          'source_id': b.sourceId,
          'last_chapter': b.lastChapter,
          'progress': b.progress,
          'group': b.group,
          'last_read_at': b.lastReadAt.toIso8601String(),
        }).toList(),
        'book_sources': sources.map((s) => {
          'id': s.id,
          'name': s.name,
          'book_source_url': s.bookSourceUrl,
          'book_source_group': s.bookSourceGroup,
          'enabled': s.enabled,
          'rules': s.rules,
        }).toList(),
      };

      final json = jsonEncode(backup);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/easyread_backup_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(json);
      return file.path;
    } catch (e) {
      return null;
    }
  }

  /// 从文件恢复备份
  Future<String?> restoreBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return '未选择文件';

      final bytes = result.files.first.bytes;
      if (bytes == null) return '读取文件失败';

      final content = String.fromCharCodes(bytes);
      final data = jsonDecode(content) as Map<String, dynamic>;

      // 恢复书架
      final books = (data['books'] as List? ?? []);
      for (final item in books) {
        final map = item as Map<String, dynamic>;
        await bookshelfRepo.save(Book(
          id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name: map['name']?.toString() ?? '未命名',
          author: map['author']?.toString(),
          coverUrl: map['cover_url']?.toString(),
          sourceId: map['source_id']?.toString(),
          lastChapter: map['last_chapter']?.toString(),
          progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
          group: map['group']?.toString(),
          lastReadAt: DateTime.tryParse(map['last_read_at']?.toString() ?? '') ?? DateTime.now(),
        ));
      }

      // 恢复书源
      final sources = (data['book_sources'] as List? ?? []);
      for (final item in sources) {
        final map = item as Map<String, dynamic>;
        await sourceRepo.save(BookSource(
          id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name: map['name']?.toString() ?? '未命名书源',
          bookSourceUrl: map['book_source_url']?.toString(),
          bookSourceGroup: map['book_source_group']?.toString(),
          enabled: map['enabled'] as bool? ?? true,
          rules: Map<String, dynamic>.from(map['rules'] as Map? ?? {}),
        ));
      }

      return '恢复成功：${books.length} 本书，${sources.length} 个书源';
    } catch (e) {
      return '恢复失败: $e';
    }
  }
}
