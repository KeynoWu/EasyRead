class Book {
  final String id;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? sourceId;
  final String? lastChapter;
  final double progress; // 0.0 ~ 1.0
  final String? group;   // 分组名称（如：正在看/已完结/囤书）
  final DateTime lastReadAt;

  const Book({
    required this.id,
    required this.name,
    this.author,
    this.coverUrl,
    this.sourceId,
    this.lastChapter,
    this.progress = 0.0,
    this.group,
    required this.lastReadAt,
  });
}
