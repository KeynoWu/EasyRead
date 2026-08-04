import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/parser/node_tree.dart';
import '../providers/reader_provider.dart';

/// 上下滚动阅读组件 — 整章连续滚动
class ReaderScrollView extends ConsumerWidget {
  const ReaderScrollView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.pages.isEmpty || state.currentChapter == null) {
      return const Center(child: Text('暂无内容'));
    }

    // 滚动模式：直接渲染整章节点（不按页拆分）
    final nodes = state.pages.expand((p) => p.nodes).toList();

    return Container(
      color: state.theme.backgroundColor,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: notifier.toggleSettings,
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: state.layoutConfig.horizontalPadding,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _buildNodes(nodes, state),
                ),
              ),
            ),
          ),
          // 章节导航栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: state.theme.backgroundColor,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: notifier.hasPrevChapter ? notifier.prevChapter : null,
                  icon: const Icon(Icons.skip_previous, size: 18),
                  label: const Text('上一章'),
                ),
                Text(
                  state.currentChapter!.title,
                  style: TextStyle(color: state.theme.textColor, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                TextButton.icon(
                  onPressed: notifier.hasNextChapter ? notifier.nextChapter : null,
                  icon: const Icon(Icons.skip_next, size: 18),
                  label: const Text('下一章'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildNodes(List<TextNode> nodes, ReaderState state) {
    return nodes.map((node) {
      switch (node.type) {
        case NodeType.paragraph:
          return Padding(
            padding: EdgeInsets.only(bottom: state.layoutConfig.paragraphSpacing),
            child: Text(
              node.text,
              style: TextStyle(
                fontSize: state.layoutConfig.fontSize,
                height: state.layoutConfig.lineHeight,
                color: state.theme.textColor,
              ),
            ),
          );
        case NodeType.heading:
          return Padding(
            padding: EdgeInsets.only(bottom: state.layoutConfig.paragraphSpacing),
            child: Text(
              node.text,
              style: TextStyle(
                fontSize: state.layoutConfig.fontSize + 4,
                fontWeight: FontWeight.w700,
                color: state.theme.textColor,
              ),
            ),
          );
        case NodeType.lineBreak:
          return const SizedBox(height: 8);
        case NodeType.text:
          return Text(
            node.text,
            style: TextStyle(
              fontSize: state.layoutConfig.fontSize,
              height: state.layoutConfig.lineHeight,
              color: state.theme.textColor,
            ),
          );
        case NodeType.image:
          return Container(
            height: 200,
            color: state.theme.textColor.withValues(alpha: 0.1),
            child: const Center(child: Icon(Icons.image, size: 48)),
          );
      }
    }).toList();
  }
}
