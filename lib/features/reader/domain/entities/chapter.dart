/// 章节实体
class Chapter {
  final String id;
  final String bookId;
  final String title;
  final String content;      // 净化后的纯文本内容
  final int index;           // 章节索引（从 0 开始）
  final String? sourceId;    // 书源 ID
  final DateTime? cachedAt;  // 缓存时间

  const Chapter({
    required this.id,
    required this.bookId,
    required this.title,
    required this.content,
    required this.index,
    this.sourceId,
    this.cachedAt,
  });

  Chapter copyWith({
    String? id,
    String? bookId,
    String? title,
    String? content,
    int? index,
    String? sourceId,
    DateTime? cachedAt,
  }) {
    return Chapter(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      title: title ?? this.title,
      content: content ?? this.content,
      index: index ?? this.index,
      sourceId: sourceId ?? this.sourceId,
      cachedAt: cachedAt ?? this.cachedAt,
    );
  }
}
