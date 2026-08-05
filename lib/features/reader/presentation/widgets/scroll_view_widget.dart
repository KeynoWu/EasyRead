import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/parser/node_tree.dart';
import '../providers/reader_provider.dart';

/// 上下滚动阅读组件 — 整章连续滚动，滚动位置按 0~1 归一化持久化。
/// 直接渲染原始 TextNode（含标题样式），不经过翻页分段；列表懒加载。
class ReaderScrollView extends ConsumerStatefulWidget {
  const ReaderScrollView({super.key});

  @override
  ConsumerState<ReaderScrollView> createState() => _ReaderScrollViewState();
}

class _ReaderScrollViewState extends ConsumerState<ReaderScrollView> {
  ScrollController? _controller;
  double _lastReportedOffset = -1;
  DateTime? _lastReportTime;
  bool _restoredOffset = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller!.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onScroll);
    _controller?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    final max = controller.position.maxScrollExtent;
    if (max <= 0) return;
    final offset = (controller.position.pixels / max).clamp(0.0, 1.0);
    final now = DateTime.now();
    // 节流：偏移变化超过 0.5% 且距上次上报至少 1 秒才上报，
    // 避免滚动时每像素触发 ReaderState 重建与 Hive 写入
    if ((offset - _lastReportedOffset).abs() < 0.005) return;
    if (_lastReportTime != null &&
        now.difference(_lastReportTime!) < const Duration(seconds: 1)) {
      return;
    }
    _lastReportTime = now;
    _lastReportedOffset = offset;
    ref.read(readerProvider.notifier).updateScrollOffset(offset);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.nodes.isEmpty || state.currentChapter == null) {
      return const Center(child: Text('暂无内容'));
    }

    // 恢复上次滚动位置：进度可能晚于章节加载完成，build 中持续检查直到恢复
    if (!_restoredOffset && state.progress != null && state.progress!.scrollOffset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _restoredOffset) return;
        final controller = _controller;
        final progress = ref.read(readerProvider).progress;
        if (controller != null &&
            controller.hasClients &&
            controller.position.maxScrollExtent > 0 &&
            progress != null &&
            progress.scrollOffset > 0) {
          controller.jumpTo(progress.scrollOffset * controller.position.maxScrollExtent);
          _restoredOffset = true;
        }
      });
    }

    return Container(
      color: state.theme.backgroundColor,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: notifier.toggleSettings,
              child: ListView.builder(
                controller: _controller,
                padding: EdgeInsets.symmetric(
                  horizontal: state.layoutConfig.horizontalPadding,
                  vertical: 16,
                ),
                itemCount: state.nodes.length,
                itemBuilder: (context, index) =>
                    _buildNode(state.nodes[index], state),
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

  Widget _buildNode(TextNode node, ReaderState state) {
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
              fontFamily: state.layoutConfig.fontFamily,
              fontFamilyFallback: state.layoutConfig.fontFamily != null ? ['serif'] : null,
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
              fontFamily: state.layoutConfig.fontFamily,
              fontFamilyFallback: state.layoutConfig.fontFamily != null ? ['serif'] : null,
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
            fontFamily: state.layoutConfig.fontFamily,
            fontFamilyFallback: state.layoutConfig.fontFamily != null ? ['serif'] : null,
          ),
        );
      case NodeType.image:
        return Container(
          height: 200,
          color: state.theme.textColor.withValues(alpha: 0.1),
          child: const Center(child: Icon(Icons.image, size: 48)),
        );
    }
  }
}
