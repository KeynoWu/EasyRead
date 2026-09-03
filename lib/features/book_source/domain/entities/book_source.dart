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
  String? get introRule => _rule('intro');
  String? get kindRule => _rule('kind');
  String? get lastChapterRule => _rule('lastChapter');
  String? get wordCountRule => _rule('wordCount');
  String? get contentUrl => _rule('contentUrl');
  String? get chapterContentRule => _rule('chapterContent');
  String? get chapterListRule => _rule('chapterList');
  String? get chapterNameRule => _rule('chapterName');
  String? get chapterUrlRule => _rule('chapterUrl');
  String? get loginUrl => rules['loginUrl'] as String?;
  String? get headerRule => _rule('header');
  String? get cookieRule => _rule('cookie');
  String? get loginCheckJs => _rule('loginCheckJs');
  String? get checkKeyWord => _nestedRule('ruleSearch', 'checkKeyWord') ??
      rules['checkKeyWord'] as String?;
  String? get exploreUrl => rules['exploreUrl'] as String?;
  String? get bookUrlPattern => rules['bookUrlPattern'] as String?;
  bool get enabledExplore => parseBool(rules['enabledExplore']) ?? false;
  bool get enabledCookieJar => parseBool(rules['enabledCookieJar']) ?? false;
  Map<String, dynamic>? get bookInfoRules {
    final nested = rules['ruleBookInfo'];
    return nested is Map ? Map<String, dynamic>.from(nested) : null;
  }

  Map<String, dynamic>? get exploreRules {
    final nested = rules['ruleExplore'];
    return nested is Map ? Map<String, dynamic>.from(nested) : null;
  }

  String? get exploreBookListRule => _exploreRule('bookList');
  String? get exploreNameRule => _exploreRule('name');
  String? get exploreAuthorRule => _exploreRule('author');
  String? get exploreCoverUrlRule => _exploreRule('coverUrl');
  String? get exploreBookUrlRule => _exploreRule('bookUrl');
  String? get exploreIntroRule => _exploreRule('intro');
  String? get exploreKindRule => _exploreRule('kind');
  String? get exploreLastChapterRule => _exploreRule('lastChapter');
  String? get exploreWordCountRule => _exploreRule('wordCount');

  String? get nextTocUrl => _nestedRule('ruleToc', 'nextTocUrl');
  String? get tocFormatJs => _nestedRule('ruleToc', 'formatJs');
  String? get tocIsVolumeRule => _nestedRule('ruleToc', 'isVolume');
  String? get nextContentUrl => _nestedRule('ruleContent', 'nextContentUrl');
  String? get contentTitleRule => _nestedRule('ruleContent', 'title');
  String? get contentSubContentRule => _nestedRule('ruleContent', 'subContent');
  String? get contentReplaceRegex => _nestedRule('ruleContent', 'replaceRegex');

  /// 源级共享 JS 库（Legado jsLib）：脚本字符串或 `{名称: 脚本|URL}` JSON，
  /// 在 JS 规则执行前注入全局作用域，供规则内的函数/常量复用。
  String? get jsLib {
    final value = rules['jsLib'];
    if (value is String && value.trim().isNotEmpty) return value;
    return null;
  }

  /// 并发率（Legado concurrentRate）：
  /// - `N/M`：M 毫秒内最多 N 次请求（滑动窗口）
  /// - 单数字：相邻请求最小间隔（毫秒）
  /// - 空 / `0`：不限制
  String? get concurrentRate {
    final value = rules['concurrentRate'];
    // JSON 数字型(legado 书源常见 `"concurrentRate": 1000`)转字符串;
    // 空白串视同未配置,`0`/`0.0` 视为不限制
    final text = value is String
        ? value.trim()
        : value is num
            ? value.toInt().toString()
            : null;
    if (text == null || text.isEmpty || num.tryParse(text) == 0) {
      return null;
    }
    return text;
  }

  /// 响应字符集：优先书源顶层 charset，其次 ruleSearch/ruleContent 内配置。
  String? get responseCharset {
    final direct = rules['charset'] ?? rules['responseCharset'];
    if (direct is String && direct.trim().isNotEmpty) return direct;
    for (final container in ['ruleSearch', 'ruleContent']) {
      final nested = rules[container];
      if (nested is Map) {
        final value = nested['charset'];
        if (value is String && value.trim().isNotEmpty) return value;
      }
    }
    return null;
  }

  String? _nestedRule(String container, String key) {
    final nested = rules[container];
    if (nested is Map) {
      final value = nested[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  String? _exploreRule(String key) {
    final nested = exploreRules;
    if (nested != null) {
      final value = nested[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return _rule(key);
  }

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
    'intro': ('ruleSearch', 'intro'),
    'kind': ('ruleSearch', 'kind'),
    'lastChapter': ('ruleSearch', 'lastChapter'),
    'wordCount': ('ruleSearch', 'wordCount'),
    'bookInfoName': ('ruleBookInfo', 'name'),
    'bookInfoAuthor': ('ruleBookInfo', 'author'),
    'bookInfoCoverUrl': ('ruleBookInfo', 'coverUrl'),
    'bookInfoIntro': ('ruleBookInfo', 'intro'),
    'bookInfoTocUrl': ('ruleBookInfo', 'tocUrl'),
    'exploreBookList': ('ruleExplore', 'bookList'),
    'exploreBookName': ('ruleExplore', 'name'),
    'exploreBookAuthor': ('ruleExplore', 'author'),
    'exploreCoverUrl': ('ruleExplore', 'coverUrl'),
    'exploreBookUrl': ('ruleExplore', 'bookUrl'),
    'chapterList': ('ruleToc', 'chapterList'),
    'chapterName': ('ruleToc', 'chapterName'),
    'chapterUrl': ('ruleToc', 'chapterUrl'),
    'nextTocUrl': ('ruleToc', 'nextTocUrl'),
    'chapterContent': ('ruleContent', 'content'),
    'contentUrl': ('ruleContent', 'contentUrl'),
    'nextContentUrl': ('ruleContent', 'nextContentUrl'),
  };

  /// 供编辑器等场景查询字段对应的 Legado 嵌套容器位置。
  static (String, String)? nestedAliasFor(String key) => _nestedAliases[key];

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
