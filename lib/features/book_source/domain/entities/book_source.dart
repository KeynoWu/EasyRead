/// 书源实体 — 兼容阅读3.0规则格式
class BookSource {
  final String id;
  final String name;
  final String? bookSourceUrl;
  final String? bookSourceGroup;
  final bool enabled;
  final Map<String, dynamic> rules;

  String? get searchUrl => rules['searchUrl'] as String?;
  String? get bookListRule => rules['bookList'] as String?;
  String? get bookNameRule => rules['bookName'] as String?;
  String? get bookAuthorRule => rules['bookAuthor'] as String?;
  String? get coverUrlRule => rules['coverUrl'] as String?;
  String? get bookDetailUrlRule => rules['bookDetailUrl'] as String?;
  String? get contentUrl => rules['contentUrl'] as String?;
  String? get chapterContentRule => rules['chapterContent'] as String?;
  String? get chapterListRule => rules['chapterList'] as String?;
  String? get chapterNameRule => rules['chapterName'] as String?;
  String? get chapterUrlRule => rules['chapterUrl'] as String?;

  const BookSource({
    required this.id,
    required this.name,
    this.bookSourceUrl,
    this.bookSourceGroup,
    this.enabled = true,
    this.rules = const {},
  });

  BookSource copyWith({
    String? id,
    String? name,
    String? bookSourceUrl,
    String? bookSourceGroup,
    bool? enabled,
    Map<String, dynamic>? rules,
  }) {
    return BookSource(
      id: id ?? this.id,
      name: name ?? this.name,
      bookSourceUrl: bookSourceUrl ?? this.bookSourceUrl,
      bookSourceGroup: bookSourceGroup ?? this.bookSourceGroup,
      enabled: enabled ?? this.enabled,
      rules: rules ?? this.rules,
    );
  }
}
