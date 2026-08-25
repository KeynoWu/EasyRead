import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
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
  bool _restoredOffset = false;
  int? _lastChapterIndex;
  /// 底部栏时间显示：每分钟刷新
  DateTime _now = DateTime.now();
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller!.addListener(_onScroll);
    // 底部时间每分钟刷新
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
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
    // 仅保留 0.5% 阈值，去掉 1 秒时间节流：时间节流会丢弃停止滚动前的
    // 最后一次位移，导致最终停留位置不落盘、续读错位。updateScrollOffset
    // 内部同样有 0.5% 阈值兜底，不会逐像素重建。
    if ((offset - _lastReportedOffset).abs() < 0.005) return;
    _lastReportedOffset = offset;
    ref.read(readerProvider.notifier).updateScrollOffset(offset);
  }

  /// 章节切换时重置滚动状态：State 因 const widget 复用不会重建，
  /// 不清空会停留在上一章的像素位置，且 _restoredOffset 会阻止新章恢复。
  void _resetForChapter() {
    _restoredOffset = false;
    _lastReportedOffset = -1;
    if (_controller?.hasClients ?? false) {
      _controller!.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    // 首次加载（无既有内容）居中转圈；切章加载保留旧内容继续显示
    if (state.isLoading && state.currentChapter == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.nodes.isEmpty || state.currentChapter == null) {
      return const Center(child: Text('暂无内容'));
    }

    final chapterIndex = state.currentChapter!.index;
    if (_lastChapterIndex != null && _lastChapterIndex != chapterIndex) {
      _resetForChapter();
    }
    _lastChapterIndex = chapterIndex;

    // 恢复上次滚动位置：进度可能晚于章节加载完成，build 中持续检查直到恢复。
    // 仅当进度确实属于当前章节时才恢复，避免套用上一章残留的 scrollOffset。
    if (!_restoredOffset &&
        state.progress != null &&
        state.progress!.scrollOffset > 0 &&
        state.progress!.chapterIndex == chapterIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _restoredOffset) return;
        final controller = _controller;
        final progress = ref.read(readerProvider).progress;
        final current = ref.read(readerProvider).currentChapter;
        if (controller != null &&
            controller.hasClients &&
            controller.position.maxScrollExtent > 0 &&
            progress != null &&
            progress.scrollOffset > 0 &&
            current != null &&
            progress.chapterIndex == current.index) {
          controller.jumpTo(
            progress.scrollOffset * controller.position.maxScrollExtent,
          );
          _restoredOffset = true;
        }
      });
    }

    return Stack(
      children: [
        Container(
          color: state.theme.backgroundColor,
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: notifier.toggleSettings,
                  // 与翻页模式一致：不包裹 SelectionArea（其 tap 手势会拦截
                  // 点击呼出菜单），选词复制待无冲突方案（见报告）。
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
              // 章节导航栏：本章滚动进度条 + 上一章/标题/下一章
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: state.theme.backgroundColor,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (state.progress?.scrollOffset ?? 0.0).clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: state.theme.textColor.withValues(alpha: 0.2),
                        color: AppColors.tint,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // 时间 + 本章进度百分比
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}',
                          style: TextStyle(
                            color: state.theme.textColor.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          '${((state.progress?.scrollOffset ?? 0.0).clamp(0.0, 1.0) * 100).round()}%',
                          style: TextStyle(
                            color: state.theme.textColor.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: notifier.hasPrevChapter
                              ? notifier.prevChapter
                              : null,
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
                          onPressed: notifier.hasNextChapter
                              ? notifier.nextChapter
                              : null,
                          icon: const Icon(Icons.skip_next, size: 18),
                          label: const Text('下一章'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 切章加载中：顶部细进度条提示，不打断旧内容阅读
        if (state.isLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
            ),
          ),
      ],
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
              fontFamilyFallback: state.layoutConfig.fontFamily != null
                  ? ['serif']
                  : null,
            ),
          ),
        );
      case NodeType.heading:
        return Padding(
          // 与分页引擎 heading 测量一致：top 4 + bottom 段落距 ×1.2
          padding: EdgeInsets.only(
            top: 4,
            bottom: state.layoutConfig.paragraphSpacing * 1.2,
          ),
          child: Text(
            node.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: state.layoutConfig.fontSize + 6,
              fontWeight: FontWeight.w700,
              height: state.layoutConfig.lineHeight,
              color: state.theme.textColor,
              fontFamily: state.layoutConfig.fontFamily,
              fontFamilyFallback: state.layoutConfig.fontFamily != null
                  ? ['serif']
                  : null,
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
            fontFamilyFallback: state.layoutConfig.fontFamily != null
                ? ['serif']
                : null,
          ),
        );
      case NodeType.image:
        return const SizedBox.shrink();
    }
  }
}
