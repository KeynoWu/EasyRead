import 'package:flutter/material.dart';

/// 解析后的文本节点类型
enum NodeType {
  text,
  paragraph,
  heading,
  image,
  lineBreak,
}

/// 解析后的文本节点
class TextNode {
  final NodeType type;
  final String text;
  final String? imageUrl;
  final int headingLevel;
  final List<TextSpan>? inlineSpans;

  const TextNode({
    required this.type,
    this.text = '',
    this.imageUrl,
    this.headingLevel = 1,
    this.inlineSpans,
  });

  bool get isBlock => type == NodeType.paragraph || type == NodeType.heading;
}
