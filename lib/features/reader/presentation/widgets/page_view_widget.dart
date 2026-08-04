import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/pagination/page_layout.dart';
import '../../core/parser/node_tree.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/reader_provider.dart';
import 'scroll_view_widget.dart';

/// 阅读器翻页组件 — PageView 驱动 + 仿真翻页动画
class ReaderPageView extends ConsumerStatefulWidget {
  const ReaderPageView({super.key});

  @override
  ConsumerState<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends ConsumerState<ReaderPageView> {
  PageController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 确保控制器存在并与当前页码同步
  void _ensureController(ReaderState state) {
    if (_controller == null || !_controller!.hasClients) {
      _controller?.dispose();
      _controller = PageController(initialPage: state.currentPage);
      return;
    }
    // 外部页码变化（如布局调整重置为 0）时同步
    final current = _controller!.page?.round() ?? state.currentPage;
    if (current != state.currentPage) {
      _controller!.jumpToPage(state.currentPage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.pages.isEmpty) {
      return const Center(child: Text('暂无内容'));
    }

    // 滚动模式
    if (state.readingMode == ReadingMode.scroll) {
      return const ReaderScrollView();
    }

    _ensureController(state);

    return Container(
      color: state.theme.backgroundColor,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: notifier.toggleSettings,
              child: PageView.builder(
                controller: _controller,
                itemCount: state.pages.length,
                onPageChanged: (index) {
                  if (index != state.currentPage) {
                    notifier.jumpToPage(index);
                  }
                },
                itemBuilder: (context, index) {
                  return _FlipPage(
                    controller: _controller!,
                    pageIndex: index,
                    child: _buildPageContent(state.pages[index], state),
                  );
                },
              ),
            ),
          ),
          // 进度条
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: state.theme.backgroundColor,
            child: Row(
              children: [
                Text(
                  '${state.currentPage + 1}/${state.pages.length}',
                  style: TextStyle(color: state.theme.textColor, fontSize: 12),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (state.currentPage + 1) / state.pages.length,
                      backgroundColor: state.theme.textColor.withOpacity(0.2),
                      color: AppColors.tint,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageContent(PageContent page, ReaderState state) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: state.layoutConfig.horizontalPadding),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: page.nodes.map((node) {
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
                  color: state.theme.textColor.withOpacity(0.1),
                  child: const Center(child: Icon(Icons.image, size: 48)),
                );
            }
          }).toList(),
        ),
      ),
    );
  }
}

/// 仿真翻页：基于滚动偏移应用轻微 3D 旋转 + 阴影
class _FlipPage extends StatelessWidget {
  final PageController controller;
  final int pageIndex;
  final Widget child;

  const _FlipPage({
    required this.controller,
    required this.pageIndex,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        var offset = 0.0;
        if (controller.position.hasContentDimensions) {
          offset = (controller.page ?? pageIndex.toDouble()) - pageIndex;
        }
        // 归一化到 -1 ~ 1，用余弦曲线让中段过渡柔和
        final progress = (offset.clamp(-1.0, 1.0)).abs();
        final angle = progress * 0.12; // 最大约 7°
        final opacity = 1.0 - progress * 0.3;

        return Transform(
          alignment: Alignment.centerRight,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(-angle * math.pi),
          child: Opacity(
            opacity: opacity,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
