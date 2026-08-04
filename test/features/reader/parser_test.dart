import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/reader/core/parser/node_tree.dart';
import 'package:easy_read/features/reader/core/parser/html_parser.dart';

void main() {
  late HtmlContentParser parser;

  setUp(() {
    parser = HtmlContentParser();
  });

  test('should parse plain text paragraph', () {
    const html = '<p>这是一段正文内容</p>';
    final nodes = parser.parse(html);
    expect(nodes.length, 1);
    expect(nodes[0].text, '这是一段正文内容');
  });

  test('should parse multiple paragraphs', () {
    const html = '<p>第一段</p><p>第二段</p><p>第三段</p>';
    final nodes = parser.parse(html);
    expect(nodes.length, 3);
    expect(nodes[0].text, '第一段');
    expect(nodes[1].text, '第二段');
    expect(nodes[2].text, '第三段');
  });

  test('should parse headings', () {
    const html = '<h1>大标题</h1><h2>中标题</h2><h3>小标题</h3>';
    final nodes = parser.parse(html);
    expect(nodes.length, 3);
    expect(nodes[0].type, NodeType.heading);
    expect(nodes[0].headingLevel, 1);
    expect(nodes[1].headingLevel, 2);
    expect(nodes[2].headingLevel, 3);
  });

  test('should handle br tags inside paragraph', () {
    const html = '<p>第一行<br>第二行</p>';
    final nodes = parser.parse(html);
    // Recursive parsing produces: text("第一行"), lineBreak, text("第二行")
    expect(nodes.length, 3);
    expect(nodes[0].text, '第一行');
    expect(nodes[1].type, NodeType.lineBreak);
    expect(nodes[2].text, '第二行');
  });

  test('should handle empty content', () {
    const html = '';
    final nodes = parser.parse(html);
    expect(nodes, isEmpty);
  });

  test('should handle mixed content', () {
    const html = '<h1>第一章</h1><p>这是正文内容。</p><p>这是第二段。</p>';
    final nodes = parser.parse(html);
    expect(nodes.length, 3);
    expect(nodes[0].type, NodeType.heading);
    expect(nodes[0].text, '第一章');
    expect(nodes[1].text, '这是正文内容。');
    expect(nodes[2].text, '这是第二段。');
  });
}
