import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

/// 第一阶段：标签净化 — 移除广告标签、script、style、无意义标签
class TagPurifier {
  static const _adKeywords = ['ad', 'advertisement', 'advert', 'banner', 'promotion', 'sponsor'];
  static const _removeTags = ['script', 'style', 'iframe', 'noscript'];

  String purify(String html) {
    final doc = parser.parse(html);
    if (doc.body != null) {
      _removeUnwanted(doc.body!);
    }
    return doc.body?.innerHtml ?? html;
  }

  void _removeUnwanted(dom.Element parent) {
    for (final tag in _removeTags) {
      parent.querySelectorAll(tag).forEach((e) => e.remove());
    }
    parent.querySelectorAll('[class]').where((e) {
      final cls = e.attributes['class']?.toLowerCase() ?? '';
      return _adKeywords.any((k) => cls.contains(k));
    }).forEach((e) => e.remove());

    parent.querySelectorAll('[id]').where((e) {
      final id = e.attributes['id']?.toLowerCase() ?? '';
      return _adKeywords.any((k) => id.contains(k));
    }).forEach((e) => e.remove());
  }
}
