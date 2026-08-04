import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

/// 第一阶段：标签净化 — 移除广告标签、script、style、无意义标签
class TagPurifier {
  static const _adKeywords = ['ad', 'ads', 'advertisement', 'advert', 'banner', 'promotion', 'sponsor'];
  static const _removeTags = ['script', 'style', 'iframe', 'noscript'];

  String purify(String html) {
    final doc = parser.parse(html);
    final body = doc.body;
    if (body != null) {
      _removeUnwanted(body);
      return body.innerHtml;
    }
    // 兜底：无 body 时对整个文档执行净化
    final root = doc.documentElement;
    if (root != null) {
      _removeUnwanted(root);
      return root.innerHtml;
    }
    return html;
  }

  void _removeUnwanted(dom.Element parent) {
    for (final tag in _removeTags) {
      parent.querySelectorAll(tag).forEach((e) => e.remove());
    }
    parent.querySelectorAll('[class]').where((e) {
      return _isAdName(e.attributes['class'] ?? '');
    }).forEach((e) => e.remove());

    parent.querySelectorAll('[id]').where((e) {
      return _isAdName(e.attributes['id'] ?? '');
    }).forEach((e) => e.remove());
  }

  /// 判断 class/id 名称是否命中广告关键词。
  /// 按空白 / 连字符 / 下划线拆分为完整词后精确匹配，避免
  /// "header"、"read-content"、"shadow" 等含 "ad" 子串的正文元素被误删。
  static bool _isAdName(String value) {
    final tokens = value.toLowerCase().split(RegExp(r'[\s_\-]+'));
    for (final token in tokens) {
      if (token.isEmpty) continue;
      if (_adKeywords.contains(token)) return true;
      // 组合词兜底，如 advertisement-box（token 前缀为关键词）
      if (_adKeywords.any((k) => k.length > 2 && token.startsWith(k))) return true;
    }
    return false;
  }
}
