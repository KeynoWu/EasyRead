/// 章节目录条目
class ChapterItem {
  final String title;
  final String url;
  final int index;
  /// 目录条目 `@put:` 保存的变量，用于正文 URL 的 `@get:{key}`。
  final Map<String, String> variables;

  const ChapterItem({
    required this.title,
    required this.url,
    required this.index,
    this.variables = const {},
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
