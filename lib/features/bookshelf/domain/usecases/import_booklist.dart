import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../../../book_source/domain/entities/book_source.dart';
import '../../../book_source/domain/repositories/book_source_repository.dart';
import '../../data/services/book_detail_service.dart';
import '../entities/book.dart';
import '../repositories/bookshelf_repository.dart';

/// 导入书单结果摘要
class ImportBooklistResult {
  /// 成功导入本数
  final int imported;

  /// 跳过本数（坏 JSON 条目 / 缺必要字段 / 书架已有同 ID）
  final int skipped;

  /// 未匹配到已启用书源本数
  final int unmatchedSource;

  /// 用户取消选择文件
  final bool canceled;

  /// 整体解析失败时的错误提示（非 null 时 counts 无意义）
  final String? error;

  const ImportBooklistResult({
    this.imported = 0,
    this.skipped = 0,
    this.unmatchedSource = 0,
    this.canceled = false,
    this.error,
  });
}

/// 导入书单：读取 legado 兼容 JSON 书单并按书源匹配批量加入书架。
///
/// 容错规则：坏 JSON / 缺必要字段（name、bookUrl）的条目跳过；
/// origin 按书源名精确匹配（大小写不敏感）已启用书源，无匹配则跳过并计数；
/// 书架已有同 ID（detailUrl base64）的书跳过（去重）。
class ImportBooklist {
  final BookshelfRepository bookshelfRepository;
  final BookSourceRepository sourceRepository;
  final BookDetailService detailService;

  ImportBooklist({
    required this.bookshelfRepository,
    required this.sourceRepository,
    required this.detailService,
  });

  /// 从本地 .json 文件导入（文件选择器选取）
  Future<ImportBooklistResult> fromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      // 必需：IO 平台默认不读取文件内容，缺省时 file.bytes 恒为 null
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return const ImportBooklistResult(canceled: true);
    }
    // 文件为 UTF-8 编码；String.fromCharCodes 会按 Latin-1 逐字节拆开中文（乱码）
    final content = utf8.decode(
      result.files.single.bytes ?? Uint8List(0),
      allowMalformed: true,
    );
    return importFromString(content);
  }

  /// 解析书单 JSON 并导入（核心逻辑，便于单测）
  Future<ImportBooklistResult> importFromString(String content) async {
    if (content.trim().isEmpty) {
      return const ImportBooklistResult(error: '书单文件为空');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      return const ImportBooklistResult(error: '书单文件不是有效的 JSON');
    }
    if (decoded is! Map) {
      return const ImportBooklistResult(error: '书单文件格式不正确');
    }
    final booksRaw = decoded['books'];
    if (booksRaw is! List) {
      return const ImportBooklistResult(error: '书单文件缺少 books 列表');
    }

    // 书源名（trim + 小写）→ 已启用书源，实现大小写不敏感匹配
    final enabled = await sourceRepository.getEnabled();
    final sourceByName = <String, BookSource>{
      for (final s in enabled) s.name.trim().toLowerCase(): s,
    };

    // 书架已有 ID 集合：既做去重，也覆盖同一文件内的重复条目
    final existingIds = (await bookshelfRepository.getAll())
        .map((b) => b.id)
        .toSet();
    final now = DateTime.now();
    var imported = 0;
    var skipped = 0;
    var unmatchedSource = 0;

    for (final raw in booksRaw) {
      if (raw is! Map) {
        skipped++;
        continue;
      }
      final name = raw['name'];
      final bookUrl = raw['bookUrl'];
      if (name is! String ||
          name.trim().isEmpty ||
          bookUrl is! String ||
          bookUrl.trim().isEmpty) {
        skipped++; // 缺必要字段（name/bookUrl）
        continue;
      }
      final origin = raw['origin'];
      final source = origin is String && origin.trim().isNotEmpty
          ? sourceByName[origin.trim().toLowerCase()]
          : null;
      if (source == null) {
        unmatchedSource++; // 未匹配到已启用书源
        continue;
      }
      // 稳定书 ID 惯例：`${sourceId}_${detailUrl base64}`（与搜索模块 _stableBookId
      // 一致），保证去重有效且进度/书签/笔记以 bookId 为键的身份体系不割裂
      final id = '${source.id}_${base64Url.encode(utf8.encode(bookUrl.trim()))}';
      if (existingIds.contains(id)) {
        skipped++; // 书架已有同 ID（去重）
        continue;
      }
      existingIds.add(id);

      final author = raw['author'];
      final lastChapter = raw['lastChapter'];
      await bookshelfRepository.save(Book(
        id: id,
        name: name.trim(),
        author: author is String ? author : null,
        sourceId: source.id,
        lastChapter: lastChapter is String ? lastChapter : null,
        lastReadAt: now,
      ));
      // 详情 URL 写入缓存，保证导入后可正常打开阅读
      await detailService.save(id, detailUrl: bookUrl.trim());
      imported++;
    }
    return ImportBooklistResult(
      imported: imported,
      skipped: skipped,
      unmatchedSource: unmatchedSource,
    );
  }
}
