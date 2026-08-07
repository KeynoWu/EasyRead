/// 书籍详情摘要，用于阅读前展示简介、作者、封面与最新章节。
class BookDetail {
  final String bookId;
  final String? name;
  final String? author;
  final String? coverUrl;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? wordCount;
  final String? tocUrl;

  const BookDetail({
    required this.bookId,
    this.name,
    this.author,
    this.coverUrl,
    this.intro,
    this.kind,
    this.lastChapter,
    this.wordCount,
    this.tocUrl,
  });
}
