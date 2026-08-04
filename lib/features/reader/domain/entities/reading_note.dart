/// 阅读笔记实体
class ReadingNote {
  final String id;
  final String bookId;
  final int chapterIndex;
  final String text;
  final DateTime createdAt;

  const ReadingNote({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.text,
    required this.createdAt,
  });
}
