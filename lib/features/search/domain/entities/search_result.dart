class SearchResult {
  final String bookId;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? detailUrl;
  final String sourceId;
  final String sourceName;
  final List<SourceOption> alternatives;

  const SearchResult({
    required this.bookId,
    required this.name,
    this.author,
    this.coverUrl,
    this.detailUrl,
    required this.sourceId,
    required this.sourceName,
    this.alternatives = const [],
  });
}

/// 可选书源
class SourceOption {
  final String bookId;
  final String sourceId;
  final String sourceName;
  final String? detailUrl;

  const SourceOption({
    required this.bookId,
    required this.sourceId,
    required this.sourceName,
    this.detailUrl,
  });
}
