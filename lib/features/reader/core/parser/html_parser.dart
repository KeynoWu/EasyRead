import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;
import 'node_tree.dart';

class HtmlContentParser {
  static const _blockTags = {'p', 'div', 'section', 'article', 'li', 'blockquote'};

  List<TextNode> parse(String html) {
    final doc = parser.parse(html);
    final body = doc.body;
    if (body == null) return [];
    final nodes = <TextNode>[];
    _parseNode(body, nodes);
    return nodes;
  }

  void _parseNode(dom.Element element, List<TextNode> nodes) {
    final buffer = StringBuffer();

    void flush() {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) {
        nodes.add(TextNode(type: NodeType.paragraph, text: text));
      }
      buffer.clear();
    }

    for (final child in element.nodes) {
      if (child is dom.Element) {
        if (_blockTags.contains(child.localName) ||
            child.localName?.startsWith('h') == true) {
          flush();
          _parseElement(child, nodes);
        } else if (child.localName == 'br') {
          buffer.writeln();
        } else {
          buffer.write(_collectInlineText(child));
        }
      } else if (child is dom.Text) {
        buffer.write(child.text);
      }
    }
    flush();
  }

  void _parseElement(dom.Element element, List<TextNode> nodes) {
    switch (element.localName) {
      case 'p':
      case 'div':
      case 'section':
      case 'article':
      case 'li':
      case 'blockquote':
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
      case 'img':
        final src = element.attributes['src'] ?? '';
        if (src.isNotEmpty) {
          nodes.add(TextNode(type: NodeType.image, imageUrl: src));
        }
        break;
      default:
        final text = element.text.trim();
        if (text.isNotEmpty) {
          nodes.add(TextNode(type: NodeType.paragraph, text: text));
        }
        break;
    }
  }

  String _collectInlineText(dom.Element element) {
    final buffer = StringBuffer();

    void walk(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.text);
      } else if (node is dom.Element) {
        if (node.localName == 'br') {
          buffer.writeln();
        } else {
          for (final child in node.nodes) {
            walk(child);
          }
        }
      }
    }

    for (final child in element.nodes) {
      walk(child);
    }
    return buffer.toString();
  }
}
