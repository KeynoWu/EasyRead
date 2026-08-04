class SearchResult {
  final String bookId;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? detailUrl;
  final String sourceId;
  final String sourceName;

  const SearchResult({
    required this.bookId,
    required this.name,
    this.author,
    this.coverUrl,
    this.detailUrl,
    required this.sourceId,
    required this.sourceName,
  });
}
