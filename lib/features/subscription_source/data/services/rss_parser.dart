import 'package:xml/xml.dart';
import '../../domain/entities/rss_entry.dart';

/// RSS 2.0 / Atom 订阅源解析器。
///
/// 容错设计：
/// - 坏 XML / 非 RSS/Atom 文档 → 返回空列表，不抛异常；
/// - 条目字段缺失/非法 → 对应字段降级为空值；
/// - 日期支持 ISO8601 与 RFC822 多格式，解析失败为 null；
/// - 命名空间容忍：按本地名（local name）匹配元素，不依赖前缀。
class RssParser {
  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// 解析 RSS 2.0（channel.item）或 Atom（feed.entry）XML，返回条目列表。
  /// 文档无法识别/解析失败时返回空列表（不抛异常）。
  static List<RssEntry> parseRss(String xml, {String sourceName = ''}) {
    return tryParse(xml, sourceName: sourceName) ?? const [];
  }

  /// 同 [parseRss]，但无法识别为 RSS/Atom 文档时返回 null
  /// （供调用方区分「解析失败」与「合法但无条目」）。
  static List<RssEntry>? tryParse(String xml, {String sourceName = ''}) {
    try {
      final root = XmlDocument.parse(xml).rootElement;
      if (root.localName == 'rss') return _parseRss2(root, sourceName);
      if (root.localName == 'feed') return _parseAtom(root, sourceName);
      return null;
    } catch (_) {
      // 坏 XML（XmlParserException 等）一律按解析失败处理
      return null;
    }
  }

  // ---- RSS 2.0 ----

  static List<RssEntry> _parseRss2(XmlElement root, String sourceName) {
    final channels = root.findElements('channel', namespaceUri: '*');
    if (channels.isEmpty) return const [];
    final channel = channels.first;
    return [
      for (final item in channel.findElements('item', namespaceUri: '*'))
        RssEntry(
          title: _childText(item, 'title') ?? '',
          link: _childText(item, 'link') ?? '',
          pubDate: parseDate(_childText(item, 'pubDate')),
          author: _childText(item, 'author'),
          // content:encoded 为完整内容，优先于 description
          description:
              _childText(item, 'encoded') ?? _childText(item, 'description'),
          sourceName: sourceName,
        ),
    ];
  }

  // ---- Atom ----

  static List<RssEntry> _parseAtom(XmlElement root, String sourceName) {
    return [
      for (final entry in root.findElements('entry', namespaceUri: '*'))
        RssEntry(
          title: _childText(entry, 'title') ?? '',
          link: _atomLink(entry) ?? '',
          pubDate: parseDate(
            _childText(entry, 'updated') ?? _childText(entry, 'published'),
          ),
          author: _atomAuthor(entry),
          // summary 为摘要；缺失时回退 content（常含正文 HTML）
          description:
              _childText(entry, 'summary') ?? _childText(entry, 'content'),
          sourceName: sourceName,
        ),
    ];
  }

  /// Atom 条目链接：优先 rel="alternate"，其次任意带 href 的 link。
  static String? _atomLink(XmlElement entry) {
    String? fallback;
    for (final link in entry.findElements('link', namespaceUri: '*')) {
      final href = link.getAttribute('href');
      if (href == null || href.isEmpty) continue;
      final rel = link.getAttribute('rel');
      if (rel == null || rel == 'alternate') return href;
      fallback ??= href;
    }
    return fallback;
  }

  /// Atom 作者：author/name 子元素文本。
  static String? _atomAuthor(XmlElement entry) {
    for (final author in entry.findElements('author', namespaceUri: '*')) {
      final name = _childText(author, 'name');
      if (name != null) return name;
    }
    return null;
  }

  // ---- 通用工具 ----

  /// 直接子元素中按本地名取首个非空文本。
  static String? _childText(XmlElement element, String localName) {
    for (final child in element.childElements) {
      if (child.localName == localName) {
        final text = child.innerText.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  /// 容错日期解析：ISO8601（DateTime.tryParse）与 RFC822
  /// （如 `Sun, 06 Nov 1994 08:49:37 GMT`、`06 Nov 94 08:49 +0800`），
  /// 均失败时返回 null。
  static DateTime? parseDate(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso;
    return _parseRfc822(s);
  }

  static final RegExp _rfc822Pattern = RegExp(
    r'^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})'
    r'\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+([A-Za-z0-9+\-:]+)$',
  );

  static DateTime? _parseRfc822(String s) {
    final m = _rfc822Pattern.firstMatch(s);
    if (m == null) return null;
    final day = int.tryParse(m.group(1)!);
    final month = _months.indexOf(m.group(2)!);
    var year = int.tryParse(m.group(3)!) ?? 0;
    final hour = int.tryParse(m.group(4)!);
    final minute = int.tryParse(m.group(5)!);
    final second = int.tryParse(m.group(6) ?? '0');
    if (day == null || month < 0 || hour == null || minute == null ||
        second == null) {
      return null;
    }
    // RFC 2822 两位年份约定：0-49 → 20xx，50-99 → 19xx
    if (year < 100) year += year < 50 ? 2000 : 1900;
    final offsetMinutes = _zoneOffset(m.group(7)!.toUpperCase());
    if (offsetMinutes == null) return null;
    // 本地墙钟时间按时区偏移换算为 UTC 时刻
    final utc = DateTime.utc(year, month + 1, day, hour, minute, second);
    return utc.subtract(Duration(minutes: offsetMinutes));
  }

  /// RFC822 时区 → UTC 偏移分钟（+0800 表示比 UTC 快 8 小时）。
  static int? _zoneOffset(String zone) {
    const named = {
      'UT': 0, 'UTC': 0, 'GMT': 0, 'Z': 0,
      'EST': -5 * 60, 'EDT': -4 * 60,
      'CST': -6 * 60, 'CDT': -5 * 60,
      'MST': -7 * 60, 'MDT': -6 * 60,
      'PST': -8 * 60, 'PDT': -7 * 60,
    };
    final known = named[zone];
    if (known != null) return known;
    final m = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(zone);
    if (m == null) return null;
    final sign = m.group(1) == '-' ? -1 : 1;
    final hh = int.tryParse(m.group(2)!) ?? 0;
    final mm = int.tryParse(m.group(3)!) ?? 0;
    return sign * (hh * 60 + mm);
  }
}
