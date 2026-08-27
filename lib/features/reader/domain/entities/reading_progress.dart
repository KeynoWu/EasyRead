/// 阅读进度实体 — 四重维度存储（章节索引 + 段落偏移 + 滚动位置 + 页码）
class ReadingProgress {
  final String bookId;
  final int chapterIndex;     // 当前章节索引
  final int paragraphOffset;  // 段落偏移
  final double scrollOffset;  // 滚动位置（0~1）
  final int pageIndex;        // 页码
  final DateTime updatedAt;   // 更新时间
  final String? sourceId;     // 书源 ID（换源后按旧索引续读会错章）

  const ReadingProgress({
    required this.bookId,
    this.chapterIndex = 0,
    this.paragraphOffset = 0,
    this.scrollOffset = 0.0,
    this.pageIndex = 0,
    required this.updatedAt,
    this.sourceId,
  });

  ReadingProgress copyWith({
    String? bookId,
    int? chapterIndex,
    int? paragraphOffset,
    double? scrollOffset,
    int? pageIndex,
    DateTime? updatedAt,
    String? sourceId,
  }) {
    return ReadingProgress(
      bookId: bookId ?? this.bookId,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      paragraphOffset: paragraphOffset ?? this.paragraphOffset,
      scrollOffset: scrollOffset ?? this.scrollOffset,
      pageIndex: pageIndex ?? this.pageIndex,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceId: sourceId ?? this.sourceId,
    );
  }
}
