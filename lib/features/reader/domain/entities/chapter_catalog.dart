/// 章节目录条目
class ChapterItem {
  final String title;
  final String url;
  final int index;

  const ChapterItem({
    required this.title,
    required this.url,
    required this.index,
  });
}

/// 章节目录
class ChapterCatalog {
  final String bookId;
  final List<ChapterItem> chapters;
  final DateTime fetchedAt;

  const ChapterCatalog({
    required this.bookId,
    this.chapters = const [],
    required this.fetchedAt,
  });
}
