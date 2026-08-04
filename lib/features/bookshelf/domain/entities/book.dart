class Book {
  final String id;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? sourceId;
  final String? lastChapter;
  final double progress;
  final DateTime lastReadAt;

  const Book({
    required this.id,
    required this.name,
    this.author,
    this.coverUrl,
    this.sourceId,
    this.lastChapter,
    this.progress = 0.0,
    required this.lastReadAt,
  });
}
