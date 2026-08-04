import 'package:flutter/material.dart';
import '../parser/node_tree.dart';

/// 排版配置
class LayoutConfig {
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double horizontalPadding;
  final FontWeight fontWeight;
  final String? fontFamily; // null = 无衬线（系统默认）

  const LayoutConfig({
    this.fontSize = 18.0,
    this.lineHeight = 1.6,
    this.paragraphSpacing = 12.0,
    this.horizontalPadding = 16.0,
    this.fontWeight = FontWeight.w400,
    this.fontFamily,
  });
}

/// 单页内容
class PageContent {
  final List<TextNode> nodes;
  final int pageIndex;

  const PageContent({required this.nodes, required this.pageIndex});
}

/// 分页布局引擎 — 使用 TextPainter 将文本拆分为多页
class PageLayout {
  final double viewWidth;
  final double viewHeight;
  final LayoutConfig config;

  PageLayout({
    required this.viewWidth,
    required this.viewHeight,
    LayoutConfig? config,
  }) : config = config ?? const LayoutConfig();

  /// 将 TextNode 列表拆分为多页
  List<PageContent> paginate(List<TextNode> nodes) {
    if (nodes.isEmpty) return [];

    final pages = <PageContent>[];
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    final contentWidth = viewWidth - config.horizontalPadding * 2;
    final contentHeight = viewHeight;

    final currentPageNodes = <TextNode>[];
    var currentPageHeight = 0.0;

    for (final node in nodes) {
      final nodeHeight = _measureNodeHeight(node, textPainter, contentWidth);

      // 如果当前节点加上当前页已超出一页，开始新页
      if (currentPageHeight + nodeHeight > contentHeight && currentPageNodes.isNotEmpty) {
        pages.add(PageContent(
          nodes: List.from(currentPageNodes),
          pageIndex: pages.length,
        ));
        currentPageNodes.clear();
        currentPageHeight = 0.0;
      }

      // 单个节点超过一页时，需要拆分
      if (nodeHeight > contentHeight && node.type == NodeType.paragraph) {
        // 拆分长段落
        final splitNodes = _splitParagraph(node, textPainter, contentWidth, contentHeight);
        for (final splitNode in splitNodes) {
          currentPageNodes.add(splitNode);
          currentPageHeight += _measureNodeHeight(splitNode, textPainter, contentWidth);
        }
      } else {
        currentPageNodes.add(node);
        currentPageHeight += nodeHeight;
      }
    }

    // 最后一页
    if (currentPageNodes.isNotEmpty) {
      pages.add(PageContent(
        nodes: List.from(currentPageNodes),
        pageIndex: pages.length,
      ));
    }

    return pages;
  }

  double _measureNodeHeight(TextNode node, TextPainter textPainter, double width) {
    switch (node.type) {
      case NodeType.text:
        textPainter.text = TextSpan(text: node.text, style: _textStyle());
        textPainter.layout(maxWidth: width);
        return textPainter.height;
      case NodeType.paragraph:
        textPainter.text = TextSpan(text: node.text, style: _textStyle());
        textPainter.layout(maxWidth: width);
        return textPainter.height + config.paragraphSpacing;
      case NodeType.heading:
        textPainter.text = TextSpan(
          text: node.text,
          style: _textStyle().copyWith(fontSize: config.fontSize + 4, fontWeight: FontWeight.w700),
        );
        textPainter.layout(maxWidth: width);
        return textPainter.height + config.paragraphSpacing;
      case NodeType.lineBreak:
        return config.fontSize * config.lineHeight * 0.5;
      case NodeType.image:
        return 200.0; // 图片占位高度
    }
  }

  /// 拆分长段落为多段
  List<TextNode> _splitParagraph(TextNode node, TextPainter textPainter, double width, double height) {
    final chars = node.text.split('');
    final result = <TextNode>[];
    final buffer = StringBuffer();

    for (int i = 0; i < chars.length; i++) {
      buffer.write(chars[i]);

      // 检查加上下一个字符是否会超出一页
      if (i + 1 < chars.length) {
        final testText = buffer.toString() + chars[i + 1];
        textPainter.text = TextSpan(text: testText, style: _textStyle());
        textPainter.layout(maxWidth: width);

        if (textPainter.height > height && buffer.toString().trim().isNotEmpty) {
          result.add(TextNode(type: NodeType.paragraph, text: buffer.toString().trim()));
          buffer.clear();
        }
      }
    }

    final remaining = buffer.toString().trim();
    if (remaining.isNotEmpty) {
      result.add(TextNode(type: NodeType.paragraph, text: remaining));
    }

    return result.isEmpty ? [node] : result;
  }

  TextStyle _textStyle() {
    return TextStyle(
      fontSize: config.fontSize,
      height: config.lineHeight,
      fontWeight: config.fontWeight,
      fontFamily: config.fontFamily,
      fontFamilyFallback: config.fontFamily != null ? ['serif'] : null,
    );
  }
}
