import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;
import 'node_tree.dart';

class HtmlContentParser {
  List<TextNode> parse(String html) {
    final doc = parser.parse(html);
    final body = doc.body;
    if (body == null) return [];
    final nodes = <TextNode>[];
    _parseNode(body, nodes);
    return nodes;
  }

  void _parseNode(dom.Element element, List<TextNode> nodes) {
    for (final child in element.nodes) {
      if (child is dom.Element) {
        _parseElement(child, nodes);
      } else if (child is dom.Text) {
        final text = child.text.trim();
        if (text.isNotEmpty) {
          nodes.add(TextNode(type: NodeType.text, text: text));
        }
      }
    }
  }

  void _parseElement(dom.Element element, List<TextNode> nodes) {
    switch (element.localName) {
      case 'p':
        _parseNode(element, nodes);
        break;
      case 'br':
        nodes.add(const TextNode(type: NodeType.lineBreak));
        break;
      case 'h1':
      case 'h2':
      case 'h3':
        final level = int.tryParse(element.localName![1]) ?? 1;
        nodes.add(TextNode(
          type: NodeType.heading,
          text: element.text.trim(),
          headingLevel: level,
        ));
        break;
      case 'strong':
      case 'b':
        nodes.add(TextNode(type: NodeType.text, text: element.text.trim()));
        break;
      case 'em':
      case 'i':
        nodes.add(TextNode(type: NodeType.text, text: element.text.trim()));
        break;
      case 'img':
        final src = element.attributes['src'] ?? '';
        if (src.isNotEmpty) {
          nodes.add(TextNode(type: NodeType.image, imageUrl: src));
        }
        break;
      case 'div':
      case 'section':
      case 'article':
        _parseNode(element, nodes);
        break;
      default:
        final text = element.text.trim();
        if (text.isNotEmpty) {
          nodes.add(TextNode(type: NodeType.text, text: text));
        }
        break;
    }
  }
}
