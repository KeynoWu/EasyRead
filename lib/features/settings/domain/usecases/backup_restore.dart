import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../../../core/database/hive_init.dart';
import '../../../../core/data/cookie_jar_service.dart';
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
      'reading_progress': await _readProgressMap(),
      'bookmarks': await _readStringBoxMap('bookmarks'),
      'reading_notes': await _readStringBoxMap('reading_notes'),
      'purification_rules': await _readStringBoxMap('purification_rules'),
      'reading_stats': await _readStringBoxMap('reading_stats'),
      'book_details': await _readStringBoxMap('book_details'),
      'source_subscriptions': await _readSubscriptionsMap(),
      'cookie_jar': await _readCookieJarMap(),
    };
    return jsonEncode(backup);
  }

  /// 从 JSON 字符串恢复（先清空再写入，语义为"还原"）。
  ///
  /// 两阶段执行：先在内存中完整解析并做类型校验，全部通过后才清空现有数据并写入。
  /// 解析失败不会触碰任何现有数据；个别坏条目（类型不符）逐条跳过而非整批失败。
  Future<String?> restoreFromJson(String content) async {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        return '恢复失败: 备份文件格式无效（应为 JSON 对象）';
      }
      final data = Map<String, dynamic>.from(decoded);

      final version = data['version'];
      if (version != null && version is! num) {
        return '恢复失败: 备份文件版本字段无效';
      }

      // === 第一阶段：内存中完整解析与校验（不触碰现有数据） ===
      final books = <Book>[];
      for (final item in (data['books'] as List? ?? const [])) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        books.add(Book(
          id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name: map['name']?.toString() ?? '未命名',
          author: map['author']?.toString(),
          coverUrl: map['cover_url']?.toString(),
          sourceId: map['source_id']?.toString(),
          lastChapter: map['last_chapter']?.toString(),
          progress: _toDouble(map['progress']),
          group: map['group']?.toString(),
          lastReadAt: DateTime.tryParse(map['last_read_at']?.toString() ?? '') ?? DateTime.now(),
        ));
      }

      final sources = <BookSource>[];
      for (final item in (data['book_sources'] as List? ?? const [])) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final rules = map['rules'];
        sources.add(BookSource(
          id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name: map['name']?.toString() ?? '未命名书源',
          bookSourceUrl: map['book_source_url']?.toString(),
          bookSourceGroup: map['book_source_group']?.toString(),
          enabled: map['enabled'] is bool ? map['enabled'] as bool : true,
          rules: rules is Map ? Map<String, dynamic>.from(rules) : <String, dynamic>{},
        ));
      }

      final progressMap = <String, ReadingProgress>{};
      final rawProgress = data['reading_progress'];
      if (rawProgress is Map) {
        for (final entry in rawProgress.entries) {
          if (entry.value is! Map) continue;
          final map = Map<String, dynamic>.from(entry.value as Map);
          progressMap[map['book_id']?.toString() ?? entry.key.toString()] = ReadingProgress(
            bookId: map['book_id']?.toString() ?? entry.key.toString(),
            chapterIndex: _toInt(map['chapter_index']),
            paragraphOffset: _toInt(map['paragraph_offset']),
            scrollOffset: _toDouble(map['scroll_offset']),
            pageIndex: _toInt(map['page_index']),
            updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? '') ?? DateTime.now(),
          );
        }
      }

      // 书签 / 笔记 / 净化规则 / 统计（JSON 字符串盒）
      const stringBoxNames = ['bookmarks', 'reading_notes', 'purification_rules', 'reading_stats', 'book_details'];
      final stringBoxes = <String, Map<String, dynamic>>{};
      for (final name in stringBoxNames) {
        final raw = data[name];
        stringBoxes[name] = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      }

      final subscriptions = <String, SourceSubscription>{};
      final rawSubs = data['source_subscriptions'];
      if (rawSubs is Map) {
        for (final entry in rawSubs.entries) {
          if (entry.value is! Map) continue;
          final map = Map<String, dynamic>.from(entry.value as Map);
          subscriptions[entry.key.toString()] = SourceSubscription(
            id: map['id']?.toString() ?? entry.key.toString(),
            name: map['name']?.toString() ?? '未命名订阅',
            url: map['url']?.toString() ?? '',
            lastUpdatedAt: DateTime.tryParse(map['last_updated_at']?.toString() ?? ''),
            lastUpdateResult: map['last_update_result']?.toString(),
          );
        }
      }

      final cookieJar = <String, String>{};
      final rawCookies = data['cookie_jar'];
      if (rawCookies is Map) {
        for (final entry in rawCookies.entries) {
          cookieJar[entry.key.toString()] = entry.value?.toString() ?? '';
        }
      }

      // === 第二阶段：解析全部通过，执行清空 + 写入 ===
      var failures = 0;
      Future<void> safe(Future<void> Function() op) async {
        try {
          await op();
        } catch (_) {
          failures++;
        }
      }

      await safe(() async {
        await _clearBox<BookModel>(HiveBoxes.bookshelf);
        for (final book in books) {
          await bookshelfRepo.save(book);
        }
      });

      await safe(() async {
        await _clearBox<BookSourceModel>(HiveBoxes.bookSources);
        for (final source in sources) {
          await sourceRepo.save(source);
        }
      });

      await safe(() async {
        await _clearBox<ReadingProgressModel>(HiveBoxes.readingProgress);
        final progressBox =
            await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
        for (final progress in progressMap.values) {
          await progressBox.put(
            progress.bookId,
            ReadingProgressModel.fromEntity(progress),
          );
        }
      });

      for (final entry in stringBoxes.entries) {
        await safe(() => _restoreStringBox(entry.key, entry.value));
      }

      await safe(() async {
        await _clearBox<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
        final subBox =
            await Hive.openBox<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
        for (final entry in subscriptions.entries) {
          await subBox.put(
            entry.key,
            SourceSubscriptionModel.fromEntity(entry.value),
          );
        }
      });

      await safe(() async {
        final cookieBox = await openSensitiveBox<String>(CookieJarService.boxName);
        await cookieBox.clear();
        for (final entry in cookieJar.entries) {
          if (entry.value.isNotEmpty) {
            await cookieBox.put(entry.key, entry.value);
          }
        }
      });

      return failures == 0
          ? '恢复成功：${books.length} 本书，${sources.length} 个书源'
          : '恢复完成：${books.length} 本书，${sources.length} 个书源，'
              '$failures 项写入失败';
    } catch (e) {
      return '恢复失败: $e';
    }
  }

  static double _toDouble(Object? value) => value is num ? value.toDouble() : 0.0;

  static int _toInt(Object? value) => value is num ? value.toInt() : 0;

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
        // 必需：IO 平台默认不读取文件内容，缺省时 file.bytes 恒为 null
        withData: true,
      );
      if (result == null || result.files.isEmpty) return '未选择文件';

      final bytes = result.files.first.bytes;
      if (bytes == null) return '读取文件失败';

      final content = utf8.decode(bytes, allowMalformed: true);
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
  Future<Map<String, dynamic>> _readStringBoxMap(String boxName) async {
    final box = await Hive.openBox<String>(boxName);
    return {for (final key in box.keys) key.toString(): box.get(key)};
  }

  /// 读取阅读进度盒（ReadingProgressModel 类型）
  Future<Map<String, dynamic>> _readProgressMap() async {
    final box = await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
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
  Future<Map<String, dynamic>> _readSubscriptionsMap() async {
    final box = await Hive.openBox<SourceSubscriptionModel>(HiveBoxes.sourceSubscriptions);
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

  /// 读取 CookieJar（String 盒）
  Future<Map<String, dynamic>> _readCookieJarMap() async {
    final box = await openSensitiveBox<String>(CookieJarService.boxName);
    return {for (final key in box.keys) key.toString(): box.get(key)};
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
