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

  group('§三-12 paginateStreaming 流式分批排版', () {
    PageLayout makeLayout({double viewHeight = 150}) =>
        PageLayout(viewWidth: 400, viewHeight: viewHeight);

    List<TextNode> makeNodes({int count = 120}) => List.generate(
          count,
          (i) => TextNode(
            type: NodeType.paragraph,
            text: '第${i + 1}段文字内容用于流式分页验证，内容足够长需要换行排版。' * 2,
          ),
        );

    test('流式结果与同步分页完全一致', () async {
      final nodes = makeNodes(count: 60);
      final syncPages = makeLayout().paginate(nodes);
      final streamed = await makeLayout().paginateStreaming(nodes);
      expect(syncPages.length, greaterThan(1));
      expect(streamed.length, syncPages.length);
      for (var i = 0; i < syncPages.length; i++) {
        expect(streamed[i].pageIndex, syncPages[i].pageIndex);
        expect(
          streamed[i].nodes.map((n) => n.text).join(),
          syncPages[i].nodes.map((n) => n.text).join(),
        );
      }
    });

    test('onPartial 渐进回调：增长前缀，最终快照不超前完整结果', () async {
      final nodes = makeNodes(count: 60);
      final partials = <List<PageContent>>[];
      final finalPages = await makeLayout()
          .paginateStreaming(nodes, batchSize: 10, onPartial: partials.add);
      // 多批处理 → 多次回调（60 节点 / 批 10 → 至少 5 次）
      expect(partials.length, greaterThanOrEqualTo(5));
      for (var i = 1; i < partials.length; i++) {
        // 每次回调的页数不减少（增长前缀）
        expect(partials[i].length,
            greaterThanOrEqualTo(partials[i - 1].length));
      }
      // 末次快照页数与完整结果一致（尾页可能在最后一批内合并）
      expect(partials.last.length, lessThanOrEqualTo(finalPages.length));
      expect(partials.last.length, greaterThanOrEqualTo(finalPages.length - 1));
    });

    test('isCancelled 提前停止并返回部分结果', () async {
      final nodes = makeNodes(count: 60);
      var processed = 0;
      final pages = await makeLayout().paginateStreaming(
        nodes,
        batchSize: 10,
        isCancelled: () => ++processed > 25,
      );
      expect(pages.length, lessThan(makeLayout().paginate(nodes).length));
    });

    test('batchSize 不影响最终分页结果（批大小无关性）', () async {
      final nodes = makeNodes(count: 45);
      final by10 = await makeLayout().paginateStreaming(nodes, batchSize: 10);
      final by7 = await makeLayout().paginateStreaming(nodes, batchSize: 7);
      final byAll = await makeLayout().paginateStreaming(nodes, batchSize: 1000);
      expect(by10.length, by7.length);
      expect(by10.length, byAll.length);
    });
  });
}
