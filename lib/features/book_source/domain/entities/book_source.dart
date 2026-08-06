import 'dart:convert';

/// 书源实体 — 兼容阅读3.0规则格式
class BookSource {
  final String id;
  final String name;
  final String? bookSourceUrl;
  final String? bookSourceGroup;
  final bool enabled;
  final Map<String, dynamic> rules;

  String? get searchUrl => _rule('searchUrl');
  String? get bookListRule => _rule('bookList');
  String? get bookNameRule => _rule('bookName');
  String? get bookAuthorRule => _rule('bookAuthor');
  String? get coverUrlRule => _rule('coverUrl');
  String? get bookDetailUrlRule => _rule('bookDetailUrl');
  String? get contentUrl => _rule('contentUrl');
  String? get chapterContentRule => _rule('chapterContent');
  String? get chapterListRule => _rule('chapterList');
  String? get chapterNameRule => _rule('chapterName');
  String? get chapterUrlRule => _rule('chapterUrl');
  String? get loginUrl => rules['loginUrl'] as String?;
  int? get searchWeight => parseWeight(rules['weight']);
  bool get searchable => parseBool(rules['searchable']) ?? true;

  /// Legado/阅读 3.0 规则容器名 → 内部字段名。
  /// 兼容嵌套结构：搜索规则在 ruleSearch、目录在 ruleToc、正文在 ruleContent。
  static const Map<String, (String, String)> _nestedAliases = {
    'searchUrl': ('ruleSearch', 'url'),
    'bookList': ('ruleSearch', 'bookList'),
    'bookName': ('ruleSearch', 'name'),
    'bookAuthor': ('ruleSearch', 'author'),
    'coverUrl': ('ruleSearch', 'coverUrl'),
    'bookDetailUrl': ('ruleSearch', 'bookUrl'),
    'chapterList': ('ruleToc', 'chapterList'),
    'chapterName': ('ruleToc', 'chapterName'),
    'chapterUrl': ('ruleToc', 'chapterUrl'),
    'chapterContent': ('ruleContent', 'content'),
    'contentUrl': ('ruleContent', 'contentUrl'),
  };

  /// 读取规则字段：优先顶层直接字段，其次 Legado 嵌套容器内字段
  String? _rule(String key) {
    final direct = rules[key];
    if (direct is String && direct.trim().isNotEmpty) return direct;
    final alias = _nestedAliases[key];
    if (alias != null) {
      final container = rules[alias.$1];
      if (container is Map) {
        final nested = container[alias.$2];
        if (nested is String && nested.trim().isNotEmpty) return nested;
      }
    }
    return null;
  }

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
