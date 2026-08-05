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
    // 显式帧栈替代递归：每个帧对应原 _parseNode 的一次调用（独立 buffer + 正序子节点游标）。
    // 原递归版本在深层嵌套 HTML（如 <div>×N）下会栈溢出，帧栈版本无深度限制。
    final stack = <_ParseFrame>[_ParseFrame(element)];
    while (stack.isNotEmpty) {
      final frame = stack.last;
      if (frame.index >= frame.element.nodes.length) {
        // 帧结束：flush 该帧局部 buffer（等价原递归返回前的 flush）
        final text = frame.buffer.toString().trim();
        if (text.isNotEmpty) {
          nodes.add(TextNode(type: NodeType.paragraph, text: text));
        }
        stack.removeLast();
        continue;
      }
      final child = frame.element.nodes[frame.index++];
      if (child is dom.Element) {
        if (_blockTags.contains(child.localName) ||
            child.localName?.startsWith('h') == true) {
          // flush 当前帧 buffer 后，将块级子元素作为新帧压栈（等价 _parseElement 递归）
          final text = frame.buffer.toString().trim();
          if (text.isNotEmpty) {
            nodes.add(TextNode(type: NodeType.paragraph, text: text));
          }
          frame.buffer.clear();
          switch (child.localName) {
            case 'h1':
            case 'h2':
            case 'h3':
              final level = int.tryParse(child.localName![1]) ?? 1;
              nodes.add(TextNode(
                type: NodeType.heading,
                text: child.text.trim(),
                headingLevel: level,
              ));
              break;
            case 'img':
              final src = child.attributes['src'] ?? '';
              if (src.isNotEmpty) {
                nodes.add(TextNode(type: NodeType.image, imageUrl: src));
              }
              break;
            default:
              // p/div/section/article/li/blockquote → 递归处理其内容（压帧）
              // h4-h6 等未列出的块级标签 → 扁平文本段落（与原实现一致）
              if (_blockTags.contains(child.localName)) {
                stack.add(_ParseFrame(child));
              } else {
                final text = child.text.trim();
                if (text.isNotEmpty) {
                  nodes.add(TextNode(type: NodeType.paragraph, text: text));
                }
              }
          }
        } else if (child.localName == 'br') {
          frame.buffer.writeln();
        } else {
          frame.buffer.write(_collectInlineText(child));
        }
      } else if (child is dom.Text) {
        frame.buffer.write(child.text);
      }
    }
  }

  String _collectInlineText(dom.Element element) {
    final buffer = StringBuffer();

    // 迭代 DFS 替代递归 walk，避免深层行内嵌套栈溢出
    final stack = <dom.Node>[element];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node is dom.Text) {
        buffer.write(node.text);
      } else if (node is dom.Element) {
        if (node.localName == 'br') {
          buffer.writeln();
        } else {
          for (final child in node.nodes.reversed) {
            stack.add(child);
          }
        }
      }
    }
    return buffer.toString();
  }
}

/// 解析帧：待处理的元素 + 正序子节点游标 + 该层局部文本 buffer
class _ParseFrame {
  _ParseFrame(this.element);

  final dom.Element element;
  int index = 0;
  final StringBuffer buffer = StringBuffer();
}
