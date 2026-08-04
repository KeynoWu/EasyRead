import '../entities/book.dart';
import '../repositories/bookshelf_repository.dart';

/// 书籍分组管理
class ManageBookGroup {
  final BookshelfRepository repository;

  ManageBookGroup({required this.repository});

  static const List<String> defaultGroups = ['正在看', '已完结', '囤书'];

  /// 更新书籍分组
  Future<void> setGroup(String bookId, String? group) async {
    final book = await repository.getById(bookId);
    if (book == null) return;
    await repository.save(Book(
      id: book.id,
      name: book.name,
      author: book.author,
      coverUrl: book.coverUrl,
      sourceId: book.sourceId,
      lastChapter: book.lastChapter,
      progress: book.progress,
      group: group,
      lastReadAt: book.lastReadAt,
    ));
  }

  /// 按分组筛选
  List<Book> filterByGroup(List<Book> books, String? group) {
    if (group == null) return books;
    return books.where((b) => b.group == group).toList();
  }

  /// 获取所有分组
  List<String> getAllGroups(List<Book> books) {
    final groups = <String>{...defaultGroups};
    for (final book in books) {
      if (book.group != null) groups.add(book.group!);
    }
    return groups.toList();
  }
}
