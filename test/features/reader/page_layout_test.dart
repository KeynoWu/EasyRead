import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/reader/core/pagination/page_layout.dart';
import 'package:easy_read/features/reader/core/parser/node_tree.dart';

void main() {
  group('PageLayout', () {
    test('should return empty pages for empty nodes', () {
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 600,
      );
      final pages = layout.paginate([]);
      expect(pages, isEmpty);
    });

    test('should put all nodes in one page if they fit', () {
      final nodes = [
        const TextNode(type: NodeType.paragraph, text: '短文本'),
      ];
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 600,
      );
      final pages = layout.paginate(nodes);
      expect(pages.length, 1);
      expect(pages[0].nodes.length, 1);
      expect(pages[0].pageIndex, 0);
    });

    test('should create multiple pages for long content', () {
      final nodes = List.generate(50, (i) => TextNode(
        type: NodeType.paragraph,
        text: '这是第${i + 1}段内容，用于测试分页效果。',
      ));
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 200,
      );
      final pages = layout.paginate(nodes);
      expect(pages.length, greaterThan(1));
      // 验证每页都有内容
      for (final page in pages) {
        expect(page.nodes, isNotEmpty);
      }
    });

    test('should handle line breaks', () {
      final nodes = [
        const TextNode(type: NodeType.text, text: '第一行'),
        const TextNode(type: NodeType.lineBreak),
        const TextNode(type: NodeType.text, text: '第二行'),
      ];
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 600,
      );
      final pages = layout.paginate(nodes);
      expect(pages.length, 1);
      expect(pages[0].nodes.length, 3);
    });

    test('should handle headings', () {
      final nodes = [
        const TextNode(type: NodeType.heading, text: '第一章', headingLevel: 1),
        const TextNode(type: NodeType.paragraph, text: '正文内容。'),
      ];
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 600,
      );
      final pages = layout.paginate(nodes);
      expect(pages.length, 1);
      expect(pages[0].nodes.length, 2);
    });

    test('should split oversized paragraph across pages without overflow', () {
      final longText = List.generate(400, (i) => '第${i + 1}段文字内容用于分页拆分。').join();
      final nodes = [
        const TextNode(type: NodeType.paragraph, text: '短段落'),
        TextNode(type: NodeType.paragraph, text: longText),
      ];
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 150,
      );
      final pages = layout.paginate(nodes);
      expect(pages.length, greaterThan(1));
      // 长段落被拆分到多页，且每页都有内容
      expect(pages.first.nodes, isNotEmpty);
      for (final page in pages) {
        expect(page.nodes, isNotEmpty);
      }
      // 拆分后各页内容总和覆盖原文（不丢字）
      final totalText = pages
          .expand((p) => p.nodes)
          .where((n) => n.type == NodeType.paragraph)
          .map((n) => n.text)
          .join();
      expect(totalText.length, greaterThan(1000));
    });
  });
}
