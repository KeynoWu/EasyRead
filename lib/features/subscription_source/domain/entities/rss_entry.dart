/// RSS/Atom 条目实体。
///
/// 字段可空：解析器对缺失字段容错（pubDate 解析失败为 null、
/// author/description 缺失为 null、title/link 缺失为空字符串）。
class RssEntry {
  final String title;
  final String link;
  final DateTime? pubDate;
  final String? author;
  final String? description;

  const RssEntry({
    required this.title,
    required this.link,
    this.pubDate,
    this.author,
    this.description,
  });
}
