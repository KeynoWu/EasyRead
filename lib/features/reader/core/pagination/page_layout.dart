import 'dart:math' as math;
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

  /// 浮点容差：避免恰好填满时因精度误差误判溢出
  static const double _epsilon = 0.5;

  /// 将 TextNode 列表拆分为多页
  List<PageContent> paginate(List<TextNode> nodes) {
    if (nodes.isEmpty) return [];

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    final contentWidth = math.max(0.0, viewWidth - config.horizontalPadding * 2);
    final contentHeight = viewHeight;

    final cursor = _PaginationCursor();

    for (final node in nodes) {
      _processNode(node, cursor, textPainter, contentWidth, contentHeight);
    }

    if (cursor.currentPageNodes.isNotEmpty) {
      cursor.pages.add(PageContent(
        nodes: List.from(cursor.currentPageNodes),
        pageIndex: cursor.pages.length,
      ));
    }
    return cursor.pages;
  }

  /// 流式分批排版（§三-12）：与 [paginate] 结果完全一致，但按 [batchSize]
  /// 节点一批处理，批间让渡事件循环（Future.delayed(Duration.zero)）交还
  /// UI 线程渲染帧——长章节排版不再一次性阻塞主 isolate 数百毫秒。
  ///
  /// 引擎约束：TextPainter 依赖 ParagraphBuilder，仅根 isolate 可用
  /// （实验证实后台 isolate 抛 "UI actions are only available on root
  /// isolate"），因此无法直接下沉 compute/isolate.run；分批让渡是本引擎
  /// 版本下的等价方案。
  ///
  /// [onPartial]：每批处理完回调已完成页快照（增长前缀，可用于渐进渲染/
  /// 进度展示）；[isCancelled] 返回真时提前停止并返回部分结果。
  Future<List<PageContent>> paginateStreaming(
    List<TextNode> nodes, {
    void Function(List<PageContent> donePages)? onPartial,
    int batchSize = 40,
    bool Function()? isCancelled,
  }) async {
    if (nodes.isEmpty) return [];

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );
    try {
      final contentWidth =
          math.max(0.0, viewWidth - config.horizontalPadding * 2);
      final contentHeight = viewHeight;
      final cursor = _PaginationCursor();

      var processed = 0;
      for (final node in nodes) {
        if (isCancelled?.call() ?? false) break;
        _processNode(node, cursor, textPainter, contentWidth, contentHeight);
        processed++;
        if (processed % batchSize == 0) {
          // 批间让渡：等一个事件循环轮次，UI 可渲染一帧
          await Future<void>.delayed(Duration.zero);
          onPartial?.call(_copyOf(cursor.pages));
        }
      }

      if (cursor.currentPageNodes.isNotEmpty) {
        cursor.pages.add(PageContent(
          nodes: List.from(cursor.currentPageNodes),
          pageIndex: cursor.pages.length,
        ));
      }
      onPartial?.call(_copyOf(cursor.pages));
      return cursor.pages;
    } finally {
      // 释放原生段落资源（TextPainter.text 置空以解引用旧段落）
      textPainter.text = null;
    }
  }

  List<PageContent> _copyOf(List<PageContent> pages) =>
      List.of(pages, growable: false);

  /// 单节点分页核心（同步 [paginate] 与流式 [paginateStreaming] 共用）：
  /// 放得下则入当前页；段落超高切分多段逐段分配；非段落超高入新页顶部。
  void _processNode(
    TextNode node,
    _PaginationCursor cursor,
    TextPainter textPainter,
    double contentWidth,
    double contentHeight,
  ) {
    void flushPage() {
      if (cursor.currentPageNodes.isEmpty) return;
      cursor.pages.add(PageContent(
        nodes: List.from(cursor.currentPageNodes),
        pageIndex: cursor.pages.length,
      ));
      cursor.currentPageNodes.clear();
      cursor.currentPageHeight = 0.0;
    }

    final nodeHeight = _measureNodeHeight(node, textPainter, contentWidth);

    // 当前节点放不下当前页剩余空间 → 翻页
    if (cursor.currentPageHeight + nodeHeight > contentHeight + _epsilon &&
        cursor.currentPageNodes.isNotEmpty) {
      flushPage();
    }

    if (nodeHeight <= contentHeight + _epsilon) {
      cursor.currentPageNodes.add(node);
      cursor.currentPageHeight += nodeHeight;
    } else if (node.type == NodeType.paragraph) {
      // 单个段落超高：按页高切分为多段，再逐段分配（含当前页剩余空间），保证不溢出
      // 切分目标高度扣除段落间距，使切出的每段测量高度（含间距）不超过页高
      final segments = _splitParagraph(
        node,
        textPainter,
        contentWidth,
        math.max(1.0, contentHeight - config.paragraphSpacing),
      );
      for (final segment in segments) {
        final segHeight =
            _measureNodeHeight(segment, textPainter, contentWidth);
        if (cursor.currentPageHeight + segHeight > contentHeight + _epsilon &&
            cursor.currentPageNodes.isNotEmpty) {
          flushPage();
        }
        cursor.currentPageNodes.add(segment);
        cursor.currentPageHeight += segHeight;
      }
    } else {
      // 非段落超高（罕见）：放入新页顶部，宁可截断视觉也不无限翻页
      cursor.currentPageNodes.add(node);
      cursor.currentPageHeight += nodeHeight;
    }
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
          style: _headingStyle(),
        );
        textPainter.layout(maxWidth: width);
        // 与渲染层 heading 的 padding 一致：top 4 + bottom 段落距 ×1.2
        return textPainter.height + config.paragraphSpacing * 1.2 + 4;
      case NodeType.lineBreak:
        return config.fontSize * config.lineHeight * 0.5;
      case NodeType.image:
        // 图片占位高度：不超过视口的 90%，小屏不溢出
        return math.min(200.0, math.max(40.0, viewHeight * 0.9));
    }
  }

  /// 拆分长段落为多段（每段高度不超过 [targetHeight]）。
  /// 使用二分查找定位断点，复杂度 O(n·log n)，替代逐字符测量的 O(n²)。
  List<TextNode> _splitParagraph(
    TextNode node,
    TextPainter textPainter,
    double width,
    double targetHeight,
  ) {
    final text = node.text;
    if (text.isEmpty) return [node];

    final result = <TextNode>[];
    final style = _textStyle();
    var start = 0;

    while (start < text.length) {
      // 二分查找 [start, text.length] 内能放入 targetHeight 的最长前缀
      var lo = start + 1;
      var hi = text.length;
      var best = start;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        textPainter.text = TextSpan(text: text.substring(start, mid), style: style);
        textPainter.layout(maxWidth: width);
        if (textPainter.height <= targetHeight + _epsilon) {
          best = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      // 极端情况（字体远大于页高）：至少推进一个字符，避免死循环
      if (best <= start) {
        best = start + 1;
      }
      // 不 trim 首尾空白：页面边界剥离空白会造成西文连字/字符丢失，
      // 保留原切片（仅跳过纯空白块）。渲染层不必担心，TextSpan 天然处理空白。
      final chunk = text.substring(start, best);
      if (chunk.trim().isNotEmpty) {
        result.add(TextNode(type: NodeType.paragraph, text: chunk));
      }
      start = best;
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

  /// 章节标题样式：居中标题更大一号字重，渲染层保持一致。
  TextStyle _headingStyle() => _textStyle().copyWith(
        fontSize: config.fontSize + 6,
        fontWeight: FontWeight.w700,
      );
}

/// 分页游标：跨批次累积的页列表与当前页状态（流式与同步排版共用）
class _PaginationCursor {
  final List<PageContent> pages = [];
  final List<TextNode> currentPageNodes = [];
  double currentPageHeight = 0.0;
}
