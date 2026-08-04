import 'package:file_picker/file_picker.dart';
import '../../data/services/epub_importer.dart';
import '../../data/services/txt_importer.dart';
import '../entities/book.dart';
import '../repositories/bookshelf_repository.dart';

/// 导入本地书籍（TXT/EPUB）
class ImportLocalBook {
  final BookshelfRepository repository;

  ImportLocalBook({required this.repository});

  /// 从本地文件导入
  Future<Book?> fromFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return null;

    final fileName = file.name;
    if (fileName.toLowerCase().endsWith('.txt')) {
      final (title, _) = TxtImporter.parseTxt(bytes, fileName);
      final book = Book(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: title,
        lastReadAt: DateTime.now(),
      );
      await repository.save(book);
      return book;
    }

    if (fileName.toLowerCase().endsWith('.epub')) {
      final (title, chapters) = EpubImporter.parseEpub(bytes);
      final book = Book(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: title,
        lastChapter: chapters.isEmpty ? null : chapters.first.$1,
        lastReadAt: DateTime.now(),
      );
      await repository.save(book);
      return book;
    }

    return null;
  }
}
