import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/pagination/page_layout.dart';
import '../../core/pagination/phonetic_annotator.dart';
import '../../core/parser/node_tree.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/reader_provider.dart';
import 'scroll_view_widget.dart';

/// 阅读器翻页组件 — PageView 驱动，按 PageTurnStyle 切换仿真/滑动/覆盖翻页动画
class ReaderPageView extends ConsumerStatefulWidget {
  const ReaderPageView({super.key});

  @override
  ConsumerState<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends ConsumerState<ReaderPageView> {
  PageController? _controller;
  /// 上次上报的视口尺寸：仅尺寸变化时才注册 postFrame，避免每次 build 都上报
  Size? _lastReportedSize;

  @override
  void initState() {
    super.initState();
    // 注音开关：异步从独立 Hive 盒加载 + 监听变更，切换实时生效
    PhoneticSettings.ensureLoaded();
    PhoneticSettings.enabled.addListener(_onPhoneticChanged);
  }

  void _onPhoneticChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PhoneticSettings.enabled.removeListener(_onPhoneticChanged);
    _controller?.dispose();
    super.dispose();
  }

  /// 当前是否横屏双栏（宽 > 高）：以分页所用视口为唯一判定来源，
  /// 与 reader_provider 的分页宽度减半 / 翻页步长逻辑保持一致。
  bool _isDualColumn(ReaderState state) =>
      state.viewportSize.width > state.viewportSize.height;

  /// 双栏模式下的屏幕总数（每屏并排两页，末屏可能只有左栏一页）
  int _screenCount(ReaderState state) =>
      _isDualColumn(state) ? (state.pages.length + 1) ~/ 2 : state.pages.length;

  /// 确保控制器存在并与当前页码同步。
  /// 双栏时 PageView 索引是屏幕序号（= 页码 ~/ 2），竖屏时索引即页码。
  void _ensureController(ReaderState state) {
    final page = _isDualColumn(state)
        ? state.currentPage ~/ 2
        : state.currentPage;
    if (_controller == null || !_controller!.hasClients) {
      _controller?.dispose();
      _controller = PageController(initialPage: page);
      return;
    }
    // 外部页码变化（如布局调整重置为 0）时同步
    final current = _controller!.page?.round() ?? page;
    if (current != page) {
      _controller!.jumpToPage(page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                state.errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: notifier.retryLoad,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 滚动模式：由 ReaderScrollView 自行处理加载 / 空内容，
    // 不依赖分页产物（延迟分页时 pages 可能为空但 nodes 已有内容）
    if (state.readingMode == ReadingMode.scroll) {
      return const ReaderScrollView();
    }

    return Container(
      color: state.theme.backgroundColor,
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(builder: (context, area) {
              // 真实页面区域视口（不含底部进度条）上报分页引擎（帧末执行，
              // 避免 build 中改状态）；仅尺寸与上次不同时才注册回调，避免
              // 每次 build 都触发上报。分页高度必须与页面区域一致，否则页
              // 内容（含段距）会超出区域高度触发溢出裁切。
              final areaSize = Size(area.maxWidth, area.maxHeight);
              if (area.maxWidth > 0 &&
                  area.maxHeight > 0 &&
                  _lastReportedSize != areaSize) {
                _lastReportedSize = areaSize;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _lastReportedSize == areaSize) {
                    ref
                        .read(readerProvider.notifier)
                        .setViewport(area.maxWidth, area.maxHeight);
                  }
                });
              }

              if (state.pages.isEmpty) {
                return const Center(child: Text('暂无内容'));
              }

              _ensureController(state);

              return GestureDetector(
                onTap: notifier.toggleSettings,
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _screenCount(state),
                  onPageChanged: (index) {
                    // 双栏：屏幕序号 → 左栏页码（每屏两页）；竖屏：索引即页码
                    final page = _isDualColumn(state) ? index * 2 : index;
                    if (page != state.currentPage) {
                      notifier.jumpToPage(page);
                    }
                  },
                  itemBuilder: (context, index) => _buildScreen(state, index),
                ),
              );
            }),
          ),
            // 进度条（pages 为空：初始/视口未上报/空章节——显示 0/0 不除零，
            // LinearProgressIndicator 在 debug 下对 >1 的值断言崩溃）
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: state.theme.backgroundColor,
              child: Row(
                children: [
                  Text(
                    state.pages.isEmpty
                        ? '0/0'
                        : '${state.currentPage + 1}/${state.pages.length}',
                    style: TextStyle(color: state.theme.textColor, fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: state.pages.isEmpty
                            ? 0.0
                            : (state.currentPage + 1) / state.pages.length,
                        backgroundColor: state.theme.textColor.withValues(alpha: 0.2),
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

  /// 正文文本渲染：注音开关开启时用 Text.rich 给生僻字加小字拼音，
  /// 关闭时原样 Text（默认路径零开销）。开关值来自 PhoneticSettings
  /// （initState 异步加载 + 盒变更监听实时刷新）。
  Widget _buildNodeText(String text, TextStyle style, ReaderState state) {
    if (!PhoneticSettings.enabled.value) {
      return Text(text, style: style);
    }
    return PhoneticAnnotator.annotatedText(
      text,
      style: style,
      annotationColor: state.theme.textColor.withValues(alpha: 0.45),
    );
  }

  Widget _buildPageContent(PageContent page, ReaderState state) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: state.layoutConfig.horizontalPadding),
      // 分页引擎已按页高切分内容，页内不再允许滚动：
      // 否则单页可滚动且翻页后滚动位置不重置，与 PageView 手势冲突
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: page.nodes.map((node) {
          switch (node.type) {
            case NodeType.paragraph:
              return Padding(
                padding: EdgeInsets.only(bottom: state.layoutConfig.paragraphSpacing),
                child: _buildNodeText(
                  node.text,
                  TextStyle(
                    fontSize: state.layoutConfig.fontSize,
                    height: state.layoutConfig.lineHeight,
                    color: state.theme.textColor,
                    fontFamily: state.layoutConfig.fontFamily,
                    fontFamilyFallback: state.layoutConfig.fontFamily != null ? ['serif'] : null,
                  ),
                  state,
                ),
              );
            case NodeType.heading:
              return Padding(
                padding: EdgeInsets.only(bottom: state.layoutConfig.paragraphSpacing),
                child: _buildNodeText(
                  node.text,
                  TextStyle(
                    fontSize: state.layoutConfig.fontSize + 4,
                    fontWeight: FontWeight.w700,
                    color: state.theme.textColor,
                    fontFamily: state.layoutConfig.fontFamily,
                    fontFamilyFallback: state.layoutConfig.fontFamily != null ? ['serif'] : null,
                  ),
                  state,
                ),
              );
            case NodeType.lineBreak:
              return const SizedBox(height: 8);
            case NodeType.text:
              return _buildNodeText(
                node.text,
                TextStyle(
                  fontSize: state.layoutConfig.fontSize,
                  height: state.layoutConfig.lineHeight,
                  color: state.theme.textColor,
                  fontFamily: state.layoutConfig.fontFamily,
                  fontFamilyFallback: state.layoutConfig.fontFamily != null ? ['serif'] : null,
                ),
                state,
              );
            case NodeType.image:
              return _buildImage(node, state);
          }
        }).toList(),
      ),
    );
  }

  /// 构建单屏内容：双栏模式并排渲染两页（左=第 2i 页、右=第 2i+1 页，
  /// 末页无下一页时右栏显示"本章完"占位）；竖屏渲染单页。
  /// 翻页动画按屏幕粒度包裹：双栏时整屏翻动，翻页手势/页码/进度逻辑不变。
  Widget _buildScreen(ReaderState state, int index) {
    final content = _isDualColumn(state)
        ? _buildDualPage(state, index)
        : _buildPageContent(state.pages[index], state);
    return switch (state.pageTurnStyle) {
      PageTurnStyle.flip => _FlipPage(
          controller: _controller!,
          pageIndex: index,
          child: content,
        ),
      // 滑动：PageView 默认水平滑动过渡
      PageTurnStyle.slide => content,
      PageTurnStyle.cover => _CoverPage(
          controller: _controller!,
          pageIndex: index,
          child: content,
        ),
    };
  }

  /// 双栏屏幕：左栏 = 第 [index*2] 页，右栏 = 下一页；末屏右栏无内容时显示占位。
  /// 分页已按半屏宽度切分（见 reader_provider._paginate），两栏文本宽度
  /// 与分页测量宽度一致，不会发生重排溢出。
  Widget _buildDualPage(ReaderState state, int index) {
    final leftIndex = index * 2;
    final rightIndex = leftIndex + 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildPageContent(state.pages[leftIndex], state)),
        Expanded(
          child: rightIndex < state.pages.length
              ? _buildPageContent(state.pages[rightIndex], state)
              : _buildChapterEndPlaceholder(state),
        ),
      ],
    );
  }

  /// 章节末尾占位：双栏末屏只有左栏内容时，右栏显示"本章完"
  Widget _buildChapterEndPlaceholder(ReaderState state) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: state.layoutConfig.horizontalPadding,
      ),
      child: Center(
        child: Text(
          '本章完',
          style: TextStyle(
            fontSize: state.layoutConfig.fontSize,
            color: state.theme.textColor.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(TextNode node, ReaderState state) {
    final url = node.imageUrl;
    return Container(
      height: 200,
      width: double.infinity,
      color: state.theme.textColor.withValues(alpha: 0.1),
      child: url == null || url.isEmpty
          ? const Center(child: Icon(Icons.image, size: 48))
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Center(child: Icon(Icons.image, size: 48)),
              loadingBuilder: (context, child, progress) =>
                  progress == null
                      ? child
                      : const Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
            ),
    );
  }
}

/// 覆盖翻页：正向翻页时下一页从右侧盖上来，反向时上一页留在原位、当前页向右滑出
/// （视觉镜像）。被盖住的页面保持原位并轻微压暗，盖上的页面带左缘投影增加层次感。
class _CoverPage extends StatelessWidget {
  final PageController controller;
  final int pageIndex;
  final Widget child;

  const _CoverPage({
    required this.controller,
    required this.pageIndex,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        var pos = 0.0;
        if (controller.position.hasContentDimensions) {
          pos = pageIndex - (controller.page ?? pageIndex.toDouble());
        }
        final width = controller.position.viewportDimension;
        // 右侧页（正向翻入）随滚动水平移动；当前页/左侧页留在原位被盖住
        final dx = pos > 0 ? pos * width : 0.0;
        final progress = pos.abs().clamp(0.0, 1.0);
        // 被盖住的页面随覆盖进度轻微压暗，突出层次
        final opacity = 1.0 - (pos <= 0 ? progress : 0.0) * 0.15;

        return Transform.translate(
          offset: Offset(dx, 0),
          child: Opacity(
            opacity: opacity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                child!,
                // 盖上页的左缘投影：覆盖进度越大越明显
                if (pos > 0)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 48 * progress,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withValues(alpha: 0.25 * progress),
                              Colors.transparent,
                            ],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
      child: child,
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
