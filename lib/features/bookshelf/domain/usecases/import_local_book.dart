import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../reader/data/models/chapter_model.dart';
import '../../../reader/domain/entities/chapter.dart';
import '../../data/services/epub_importer.dart';
import '../../data/services/txt_importer.dart';
import '../entities/book.dart';
import '../repositories/bookshelf_repository.dart';

/// 本地书阅读使用的固定书源标识（无真实书源，章节直读缓存）
const String localSourceId = 'local';

/// 导入本地书籍（TXT/EPUB）
class ImportLocalBook {
  final BookshelfRepository repository;

  ImportLocalBook({required this.repository});

  /// 从本地文件导入（支持多选）。解析出的章节写入章节缓存，
  /// 阅读器通过 bookId + local 书源直接命中缓存。
  Future<List<Book>> fromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub'],
      allowMultiple: true,
      // 必需：IO 平台默认不读取文件内容，缺省时 file.bytes 恒为 null
      withData: true,
    );
    if (result == null || result.files.isEmpty) return [];

    final imported = <Book>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      final book = await _importOne(file.name, bytes);
      if (book != null) imported.add(book);
    }
    return imported;
  }

  Future<Book?> _importOne(String fileName, Uint8List bytes) async {
    // 微秒级时间戳，避免多文件同一毫秒导入时 ID 碰撞
    final id = DateTime.now().microsecondsSinceEpoch.toString();

    if (fileName.toLowerCase().endsWith('.txt')) {
      // 解析移入后台 isolate：大文件解码/分行耗时可达数十秒，不能卡 UI 线程。
      // compute 要求参数/返回值可跨 isolate 发送，record 与 Uint8List 均满足。
      final (title, chapters) = await compute(TxtImporter.parseTxtForCompute, (bytes, fileName));
      if (chapters.isEmpty) return null;
      await _saveChapters(id, chapters);
      final book = Book(
        id: id,
        name: title,
        sourceId: localSourceId,
        lastChapter: chapters.isEmpty ? null : chapters.last.$1,
        lastReadAt: DateTime.now(),
      );
      await repository.save(book);
      return book;
    }

    if (fileName.toLowerCase().endsWith('.epub')) {
      final (title, chapters) = await compute(EpubImporter.parseEpub, bytes);
      if (chapters.isEmpty) return null;
      await _saveChapters(id, chapters);
      final book = Book(
        id: id,
        name: title,
        sourceId: localSourceId,
        lastChapter: chapters.isEmpty ? null : chapters.last.$1,
        lastReadAt: DateTime.now(),
      );
      await repository.save(book);
      return book;
    }

    return null;
  }

  /// 章节写入缓存盒，key 与阅读器缓存格式一致：{bookId}_{sourceId}_{index}
  Future<void> _saveChapters(String bookId, List<(String, String)> chapters) async {
    if (chapters.isEmpty) return;
    final box = await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
    // 批量写入：逐条 await 会放大 Hive 同步写盘的停顿，putAll 一次性提交
    final now = DateTime.now();
    final entries = <String, ChapterModel>{
      for (int i = 0; i < chapters.length; i++)
        '${bookId}_${localSourceId}_$i': ChapterModel.fromEntity(Chapter(
          id: '${bookId}_${localSourceId}_$i',
          bookId: bookId,
          title: chapters[i].$1,
          content: chapters[i].$2,
          index: i,
          sourceId: localSourceId,
          cachedAt: now,
        )),
    };
    await box.putAll(entries);
  }
}
