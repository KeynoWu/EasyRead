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
  const TextNode({
    required this.type,
    this.text = '',
    this.imageUrl,
    this.headingLevel = 1,
  });
}
