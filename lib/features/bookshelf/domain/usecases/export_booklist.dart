import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../../../book_source/domain/repositories/book_source_repository.dart';
import '../../data/services/book_detail_service.dart';
import '../entities/book.dart';

/// 导出书单：生成 legado 兼容 JSON 并保存为本地文件。
///
/// 导出格式（与 legado 书单文件对齐）：
/// {"name": "书单名", "books": [{"name","author","kind","origin","bookUrl","intro","lastChapter"}]}
/// 其中 origin = 书源名（按 sourceId 反查）、bookUrl = 书籍详情 URL。
class ExportBooklist {
  /// 默认书单名：未指定时作为 JSON name 与导出文件名前缀
  static const String defaultBooklistName = '我的书单';

  final BookSourceRepository sourceRepository;
  final BookDetailService detailService;

  ExportBooklist({
    required this.sourceRepository,
    required this.detailService,
  });

  /// 导出文件名（默认：书单名.json）
  String defaultFileName(String booklistName) => '$booklistName.json';

  /// 构建 legado 兼容书单 JSON 字符串。
  /// 书架未持久化 kind/intro，导出为 null；origin 无对应书源时导出为 null。
  Future<String> buildJson(
    List<Book> books, {
    String booklistName = defaultBooklistName,
  }) async {
    final sources = await sourceRepository.getAll();
    final sourceNameById = {for (final s in sources) s.id: s.name};
    final entries = <Map<String, dynamic>>[];
    for (final book in books) {
      final detail = await detailService.get(book.id);
      entries.add({
        'name': book.name,
        'author': book.author,
        'kind': null,
        'origin': sourceNameById[book.sourceId],
        'bookUrl': detail?.detailUrl,
        'intro': null,
        'lastChapter': book.lastChapter,
      });
    }
    return jsonEncode({'name': booklistName, 'books': entries});
  }

  /// 调起系统保存对话框并写入文件，返回供 SnackBar 展示的结果消息。
  Future<String> saveToFile(
    String json, {
    String booklistName = defaultBooklistName,
  }) async {
    final fileName = defaultFileName(booklistName);
    try {
      // Android/iOS 上 saveFile 必须传 bytes（返回 content:// URI 无法用 File 写入）
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出书单',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      if (path == null) return '已取消导出';
      return '书单已导出：$fileName';
    } catch (_) {
      return '导出失败，请重试';
    }
  }
}
