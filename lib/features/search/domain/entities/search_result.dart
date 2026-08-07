class SearchResult {
  final String bookId;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? detailUrl;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? wordCount;
  final String sourceId;
  final String sourceName;
  final List<SourceOption> alternatives;
  /// 书源规则 `@put:` 保存的变量，用于详情/目录 URL 的 `@get:{key}`。
  final Map<String, String> variables;

  const SearchResult({
    required this.bookId,
    required this.name,
    this.author,
    this.coverUrl,
    this.detailUrl,
    this.intro,
    this.kind,
    this.lastChapter,
    this.wordCount,
    required this.sourceId,
    required this.sourceName,
    this.alternatives = const [],
    this.variables = const {},
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
