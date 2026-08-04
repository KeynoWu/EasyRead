import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../../../core/database/hive_init.dart';
import '../../../book_source/data/models/book_source_model.dart';
import '../../../book_source/data/models/source_subscription_model.dart';
import '../../../book_source/domain/entities/source_subscription.dart';
import '../../../book_source/domain/entities/book_source.dart';
import '../../../book_source/domain/repositories/book_source_repository.dart';
import '../../../bookshelf/data/models/book_model.dart';
import '../../../bookshelf/domain/entities/book.dart';
import '../../../bookshelf/domain/repositories/bookshelf_repository.dart';
import '../../../reader/data/models/reading_progress_model.dart';
import '../../../reader/domain/entities/reading_progress.dart';

/// 备份与恢复 — 覆盖书架、书源、阅读进度、书签、笔记、净化规则、阅读统计、订阅
class BackupRestore {
  final BookshelfRepository bookshelfRepo;
  final BookSourceRepository sourceRepo;

  BackupRestore({
    required this.bookshelfRepo,
    required this.sourceRepo,
  });

  /// 生成备份 JSON 字符串
  Future<String> buildBackupJson() async {
    final books = await bookshelfRepo.getAll();
    final sources = await sourceRepo.getAll();

    final backup = {
      'version': 2,
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
      'reading_progress': _readProgressMap(),
      'bookmarks': _readStringBoxMap('bookmarks'),
      'reading_notes': _readStringBoxMap('reading_notes'),
      'purification_rules': _readStringBoxMap('purification_rules'),
      'reading_stats': _readStringBoxMap('reading_stats'),
      'source_subscriptions': _readSubscriptionsMap(),
    };
    return jsonEncode(backup);
  }

  /// 从 JSON 字符串恢复（先清空再写入，语义为"还原"）
  Future<String?> restoreFromJson(String content) async {
    try {
      final data = jsonDecode(content) as Map<String, dynamic>;

      // 书架
      final books = (data['books'] as List? ?? []);
      await _clearBox<BookModel>(HiveBoxes.bookshelf);
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

      // 书源
      final sources = (data['book_sources'] as List? ?? []);
      await _clearBox<BookSourceModel>(HiveBoxes.bookSources);
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

      // 阅读进度
      final progressMap = data['reading_progress'] as Map? ?? {};
      await _clearBox<ReadingProgressModel>(HiveBoxes.readingProgress);
      for (final entry in progressMap.entries) {
        final map = (entry.value as Map).cast<String, dynamic>();
        final progress = ReadingProgress(
          bookId: map['book_id']?.toString() ?? entry.key.toString(),
          chapterIndex: (map['chapter_index'] as num?)?.toInt() ?? 0,
          paragraphOffset: (map['paragraph_offset'] as num?)?.toInt() ?? 0,
          scrollOffset: (map['scroll_offset'] as num?)?.toDouble() ?? 0,
          pageIndex: (map['page_index'] as num?)?.toInt() ?? 0,
          updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? '') ?? DateTime.now(),
        );
        final box = await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
        await box.put(progress.bookId, ReadingProgressModel.fromEntity(progress));
      }

      // 书签 / 笔记 / 净化规则 / 统计（JSON 字符串盒）
      await _restoreStringBox('bookmarks', data['bookmarks']);
      await _restoreStringBox('reading_notes', data['reading_notes']);
      await _restoreStringBox('purification_rules', data['purification_rules']);
      await _restoreStringBox('reading_stats', data['reading_stats']);

      // 订阅
      final subs = data['source_subscriptions'] as Map? ?? {};
      await _clearBox<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
      for (final entry in subs.entries) {
        final map = (entry.value as Map).cast<String, dynamic>();
        final box = await Hive.openBox<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
        await box.put(entry.key.toString(), SourceSubscriptionModel.fromEntity(
          SourceSubscription(
            id: map['id']?.toString() ?? entry.key.toString(),
            name: map['name']?.toString() ?? '未命名订阅',
            url: map['url']?.toString() ?? '',
            lastUpdatedAt: DateTime.tryParse(map['last_updated_at']?.toString() ?? ''),
            lastUpdateResult: map['last_update_result']?.toString(),
          ),
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
      final json = await buildBackupJson();
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
      return await restoreFromJson(content);
    } catch (e) {
      return '恢复失败: $e';
    }
  }

  // ---- 内部工具 ----

  Future<void> _clearBox<T>(String name) async {
    // 泛型必须与首次打开时的类型完全一致，否则 Hive 抛
    // "already open and of type Box<X>" 错误
    final box = await Hive.openBox<T>(name);
    await box.clear();
  }

  /// 读取 JSON 字符串盒为 {key: 原始JSON字符串}（用于备份）
  Map<String, dynamic> _readStringBoxMap(String boxName) {
    if (!Hive.isBoxOpen(boxName)) return {};
    final box = Hive.box<String>(boxName);
    return {for (final key in box.keys) key.toString(): box.get(key)};
  }

  /// 读取阅读进度盒（ReadingProgressModel 类型）
  Map<String, dynamic> _readProgressMap() {
    if (!Hive.isBoxOpen(HiveBoxes.readingProgress)) return {};
    final box = Hive.box<ReadingProgressModel>(HiveBoxes.readingProgress);
    final result = <String, dynamic>{};
    for (final entry in box.toMap().entries) {
      final e = entry.value.toEntity();
      result[entry.key.toString()] = {
        'book_id': e.bookId,
        'chapter_index': e.chapterIndex,
        'paragraph_offset': e.paragraphOffset,
        'scroll_offset': e.scrollOffset,
        'page_index': e.pageIndex,
        'updated_at': e.updatedAt.toIso8601String(),
      };
    }
    return result;
  }

  /// 读取书源订阅盒（SourceSubscriptionModel 类型）
  Map<String, dynamic> _readSubscriptionsMap() {
    if (!Hive.isBoxOpen(HiveBoxes.sourceSubscriptions)) return {};
    final box = Hive.box<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
    final result = <String, dynamic>{};
    for (final entry in box.toMap().entries) {
      final e = entry.value.toEntity();
      result[entry.key.toString()] = {
        'id': e.id,
        'name': e.name,
        'url': e.url,
        'last_updated_at': e.lastUpdatedAt?.toIso8601String(),
        'last_update_result': e.lastUpdateResult,
      };
    }
    return result;
  }

  /// 恢复 JSON 字符串盒（先清空）
  Future<void> _restoreStringBox(String boxName, dynamic data) async {
    final map = data as Map? ?? {};
    await _clearBox<String>(boxName);
    final box = await Hive.openBox<String>(boxName);
    for (final entry in map.entries) {
      final value = entry.value;
      await box.put(entry.key.toString(), value is String ? value : jsonEncode(value));
    }
  }
}
