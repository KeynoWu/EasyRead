import 'dart:convert';

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
  String? get loginUrl => rules['loginUrl'] as String?;
  int? get searchWeight => parseWeight(rules['weight']);
  bool get searchable => parseBool(rules['searchable']) ?? true;

  static int? parseWeight(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static bool? parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text == 'true' || text == '1') return true;
      if (text == 'false' || text == '0') return false;
    }
    return null;
  }

  /// 书源请求头：规则 header 优先，Cookie 与 Referer 兜底。
  Map<String, String> get requestHeaders {
    final headers = <String, String>{};
    final rawHeader = rules['header'];
    if (rawHeader is String && rawHeader.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawHeader);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            headers[entry.key.toString()] = entry.value?.toString() ?? '';
          }
        }
      } catch (_) {
        // 非法 header JSON 忽略，避免请求失败
      }
    }
    final cookie = rules['cookie']?.toString().trim() ?? '';
    if (cookie.isNotEmpty) {
      headers.putIfAbsent('Cookie', () => cookie);
    }
    if (bookSourceUrl != null && bookSourceUrl!.isNotEmpty) {
      headers.putIfAbsent('Referer', () => bookSourceUrl!);
    }
    return headers;
  }

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
