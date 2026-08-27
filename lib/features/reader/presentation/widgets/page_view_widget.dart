import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/pagination/page_layout.dart';
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

class _ReaderPageViewState extends ConsumerState<ReaderPageView>
    with SingleTickerProviderStateMixin {
  PageController? _controller;
  /// 上次上报的视口尺寸：仅尺寸变化时才注册 postFrame，避免每次 build 都上报
  Size? _lastReportedSize;
  /// 底部栏时间显示：每分钟刷新
  DateTime _now = DateTime.now();
  Timer? _clockTimer;
  /// 章节切换淡入动画：切章后新内容从透明淡入，避免生硬跳变。
  /// 与 AnimatedSwitcher 不同，PageView 实例不重建（controller 串行 attach），
  /// 仅 Opacity 过渡，不会引发页码/滚动位置错乱。
  late final AnimationController _chapterFade;
  /// 持有单一 CurvedAnimation：内联构造会在每次 build 向 controller 注册
  /// 一个 status listener 且无法移除（缓慢泄漏），故在 initState 创建一次。
  late final CurvedAnimation _chapterFadeCurve;
  int? _lastChapterIndex;

  @override
  void initState() {
    super.initState();
    _chapterFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1.0,
    );
    _chapterFadeCurve =
        CurvedAnimation(parent: _chapterFade, curve: Curves.easeOut);
    // 底部时间每分钟刷新
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _chapterFadeCurve.dispose();
    _chapterFade.dispose();
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
  /// 控制器只在 build 首次需要时创建一次（无 dispose 副作用）；后续页码
  /// 同步移到 postFrame（build 里 jumpToPage 会触发 markNeedsBuild during
  /// build 断言）。
  void _ensureController(ReaderState state) {
    final page = _isDualColumn(state)
        ? state.currentPage ~/ 2
        : state.currentPage;
    if (_controller == null) {
      _controller = PageController(initialPage: page);
      return;
    }
    // 外部页码变化（如布局调整重置为 0）时同步。
    if (!_controller!.hasClients) return; // 首次布局前无需同步
    final current = _controller!.page?.round() ?? page;
    if (current != page) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller?.hasClients == true) {
          _controller!.jumpToPage(page);
        }
      });
    }
  }

  /// 正文三区点击：左侧上一页（首屏切上一章）、右侧下一页（末屏切下一章）、
  /// 中间呼出菜单。双栏时以"屏"为单位判断边界（当前页=左栏页）。
  void _handleTap(
    double x,
    double width,
    ReaderState state,
    ReaderNotifier notifier,
  ) {
    // 原生触感：点击翻页/切章轻震动，增强"实体书"手感
    HapticFeedback.lightImpact();
    if (x < width / 3) {
      final atStart = state.currentPage <= 0;
      if (atStart) {
        notifier.prevChapter();
      } else {
        notifier.prevPage();
      }
    } else if (x > width * 2 / 3) {
      final pageCount = state.pages.length;
      final atEnd = pageCount <= 0 || state.currentPage >= pageCount - 1;
      if (atEnd) {
        notifier.nextChapter();
      } else {
        notifier.nextPage();
      }
    } else {
      notifier.toggleMenu();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    // 首次加载（无既有内容）居中转圈；切章加载保留旧内容，
    // 由下方 Stack 叠加顶部细进度条，避免整屏替换转圈打断阅读。
    if (state.isLoading && state.currentChapter == null) {
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

    // 章节切换淡入：章节 index 变化时新内容从透明淡入（首次加载同样生效，
    // 内容就绪后柔和呈现）；PageView 实例不重建，避免页码/滚动位置错乱。
    final chapterIndex = state.currentChapter?.index;
    if (_lastChapterIndex != chapterIndex) {
      _chapterFade.forward(from: 0);
    }
    _lastChapterIndex = chapterIndex;

    return Stack(
      children: [
        Container(
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

              // 末页右滑 / 首页左滑（iOS 回弹或 Android 辉光）触发切章；
              // 点击三区：左=上一页（首屏切上一章）、右=下一页（末屏切下一章）、
              // 中间=呼出菜单。加载中不响应，避免切章后残留手势连锁触发。
              return NotificationListener<OverscrollNotification>(
                onNotification: (notification) {
                  if (state.isLoading) return false;
                  final pageCount = state.pages.length;
                  final atEnd =
                      pageCount <= 0 || state.currentPage >= pageCount - 1;
                  final atStart = state.currentPage <= 0;
                  if (notification.overscroll < 0 && atEnd) {
                    notifier.nextChapter();
                  } else if (notification.overscroll > 0 && atStart) {
                    notifier.prevChapter();
                  }
                  return false;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _handleTap(
                    details.localPosition.dx,
                    area.maxWidth,
                    state,
                    notifier,
                  ),
                  // 注意：此处不再包裹 SelectionArea——它注册的 tap 手势会与
                  // 三区点击竞争并拦截点击，导致"点中间呼不出菜单"。
                  // 选词复制（UX-09）需改用不与点击冲突的方案（见报告）。
                  child: FadeTransition(
                    opacity: _chapterFadeCurve,
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
                      itemBuilder: (context, index) =>
                          _buildScreen(state, index),
                    ),
                  ),
                ),
              );
            }),
          ),
            // 进度条（pages 为空：初始/视口未上报/空章节——显示 0/0 不除零，
            // LinearProgressIndicator 在 debug 下对 >1 的值断言崩溃）。
            // 菜单打开时隐藏，避免与底部工具栏视觉叠层。
            if (!state.showMenu)
              Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: state.theme.backgroundColor,
              child: Row(
                children: [
                  // 当前时间
                  Text(
                    '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(color: state.theme.textColor, fontSize: 12),
                  ),
                  const SizedBox(width: 12),
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
                  // 章节导航：上一章 / 下一章（与滚动模式底部导航能力对齐）。
                  // 加载中禁用：防止快速连点对同一章节发起重复网络请求
                  // （_loadSeq 只丢弃过期结果，不合并请求）。
                  // 显式 icon color 会覆盖 IconButton 的禁用色，故按可用态
                  // 手动降透明度以提供视觉区分。
                  Builder(
                    builder: (context) {
                      final prevEnabled =
                          notifier.hasPrevChapter && !state.isLoading;
                      final nextEnabled =
                          notifier.hasNextChapter && !state.isLoading;
                      final textColor = state.theme.textColor;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              Icons.skip_previous,
                              size: 20,
                              color: prevEnabled
                                  ? textColor.withValues(alpha: 0.7)
                                  : textColor.withValues(alpha: 0.25),
                            ),
                            onPressed:
                                prevEnabled ? notifier.prevChapter : null,
                            visualDensity: VisualDensity.compact,
                            tooltip: '上一章',
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.skip_next,
                              size: 20,
                              color: nextEnabled
                                  ? textColor.withValues(alpha: 0.7)
                                  : textColor.withValues(alpha: 0.25),
                            ),
                            onPressed:
                                nextEnabled ? notifier.nextChapter : null,
                            visualDensity: VisualDensity.compact,
                            tooltip: '下一章',
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
        // 竖屏末页提示：本章最后一页显示"本章完"，点击直接进入下一章。
        // 双栏末屏已有右栏占位（_buildChapterEndPlaceholder），不再重复。
        if (!_isDualColumn(state) &&
            state.pages.isNotEmpty &&
            state.currentPage >= state.pages.length - 1 &&
            notifier.hasNextChapter &&
            !state.isLoading)
          Positioned(
            left: 24,
            right: 24,
            bottom: 56,
            child: Center(
              child: Material(
                color: state.theme.textColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: notifier.nextChapter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      '本章完 · 点击进入下一章',
                      style: TextStyle(
                        color: state.theme.textColor.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
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
              color: AppColors.tint,
            ),
          ),
      ],
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
                // 与分页引擎 heading 测量一致：top 4 + bottom 段落距 ×1.2
                padding: EdgeInsets.only(
                  top: 4,
                  bottom: state.layoutConfig.paragraphSpacing * 1.2,
                ),
                // Column 为 start 对齐：Text 按固有宽度布局时 textAlign 无效，
                // 必须拉满整宽才能让标题真正水平居中（与滚动模式 ListView 行为一致）
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    node.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: state.layoutConfig.fontSize + 6,
                      fontWeight: FontWeight.w700,
                      height: state.layoutConfig.lineHeight,
                      color: state.theme.textColor,
                      fontFamily: state.layoutConfig.fontFamily,
                      fontFamilyFallback: state.layoutConfig.fontFamily != null ? ['serif'] : null,
                    ),
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
              return buildImageNode(node, state);
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
