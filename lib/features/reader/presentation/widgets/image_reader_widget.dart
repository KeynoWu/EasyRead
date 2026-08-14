import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/reader_provider.dart';

/// 图片/漫画阅读视图 — 横向 PageView 逐图阅读（对齐 legado 图片阅读）。
///
/// 仅用于图片章节（isImageChapter）：每页一张图，黑色背景 + fit contain；
/// 单指左右滑动换图（调用 notifier.jumpToPage 复用翻页与进度模型）；
/// 双击切换 1x/2x 缩放、双指捏合任意缩放，缩放后单指拖拽平移图片；
/// 单击切换设置栏；底部显示页码指示（当前/总数）。
/// 图片 URL 已由上层 resolveImageUrls 解析为绝对地址，直接走 Image.network。
class ImageReaderWidget extends ConsumerStatefulWidget {
  const ImageReaderWidget({super.key});

  @override
  ConsumerState<ImageReaderWidget> createState() => _ImageReaderWidgetState();
}

class _ImageReaderWidgetState extends ConsumerState<ImageReaderWidget> {
  PageController? _controller;
  /// 上次上报的视口尺寸：仅尺寸变化时才注册 postFrame，避免每次 build 都上报。
  /// 图片章节虽不分页，但需保持 _viewportReported 标记，保证后续切到文本
  /// 章节时首帧即可分页（与 ReaderPageView 上报语义一致）。
  Size? _lastReportedSize;
  /// 任一页面是否处于缩放状态：缩放时禁用 PageView 翻页手势，
  /// 让单指拖拽用于平移图片（否则 18px 触控滑距内 PageView 优先赢下竞技场）
  bool _anyZoomed = false;
  /// 章节 id：章节切换时重置缩放状态与控制器，避免上一章残留
  String? _lastChapterId;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }


  /// 确保控制器存在并与当前图片索引同步（外部跳页/恢复进度时校正）
  void _ensureController(ReaderState state, List<String> urls) {
    final page = state.currentPage.clamp(0, urls.length - 1);
    if (_controller == null || !_controller!.hasClients) {
      _controller?.dispose();
      _controller = PageController(initialPage: page);
      return;
    }
    final current = _controller!.page?.round() ?? page;
    if (current != page) {
      // 帧末同步：build 期间 jumpToPage 触发控制器通知有
      // markNeedsBuild during build 断言风险。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller?.hasClients == true) {
          _controller!.jumpToPage(page);
        }
      });
    }
  }

  /// 页面缩放状态变化回调：任一页放大后禁用 PageView 翻页（平移优先）
  void _onZoomChanged(bool zoomed) {
    if (_anyZoomed != zoomed) {
      setState(() => _anyZoomed = zoomed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);
    final urls = state.imageUrls;

    // 章节切换：清空上一章的缩放状态与控制器（重建于 _ensureController）
    final chapterId = state.currentChapter?.id;
    if (_lastChapterId != chapterId) {
      _lastChapterId = chapterId;
      _anyZoomed = false;
      _controller?.dispose();
      _controller = null;
    }

    return Container(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(builder: (context, area) {
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

              if (urls.isEmpty) {
                return const Center(
                  child: Text(
                    '暂无内容',
                    style: TextStyle(color: Colors.white70),
                  ),
                );
              }

              _ensureController(state, urls);
              return PageView.builder(
                controller: _controller,
                // 缩放中禁用翻页手势：单指拖拽留给图片平移
                physics: _anyZoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: urls.length,
                onPageChanged: (index) {
                  if (index != state.currentPage) {
                    notifier.jumpToPage(index);
                  }
                },
                itemBuilder: (context, index) => _ImagePage(
                  // key 含章节索引：切章后同 index 不复用旧页 State，
                  // 避免上一章的缩放/平移状态残留到新章节
                  key: ValueKey('${state.currentChapter?.index}-$index'),
                  url: urls[index],
                  onToggleSettings: notifier.toggleSettings,
                  onZoomChanged: _onZoomChanged,
                ),
              );
            }),
          ),
          // 页码指示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.black,
            child: Row(
              children: [
                Text(
                  '${state.currentPage + 1}/${urls.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (state.currentPage + 1) / urls.length,
                      backgroundColor: Colors.white24,
                      color: Colors.lightBlueAccent,
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
}

/// 单张图片页：InteractiveViewer 缩放（双指捏合 + 双击 1x/2x），
/// 单击切换设置栏。1x 时单指滑动由 PageView 接管翻页，缩放后单指拖拽平移。
class _ImagePage extends StatefulWidget {
  final String url;
  final VoidCallback onToggleSettings;
  final ValueChanged<bool> onZoomChanged;

  const _ImagePage({
    super.key,
    required this.url,
    required this.onToggleSettings,
    required this.onZoomChanged,
  });

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage> {
  final TransformationController _transform = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    super.dispose();
  }

  /// 监听变换矩阵：跨过 1x 阈值时同步 _zoomed 并通知父级切换翻页手势
  void _onTransformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
      widget.onZoomChanged(zoomed);
    }
  }

  /// 双击切换 1x/2x：放大以页面中心为焦点（平移-缩放-平移回原点）
  void _toggleZoom() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
      return;
    }
    final size = context.size;
    final center = (size == null) ? Offset.zero : size.center(Offset.zero);
    _transform.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(2.0, 2.0, 2.0, 1.0)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  @override
  Widget build(BuildContext context) {
    // onTap 与 onDoubleTap 注册在同一 GestureDetector：Flutter 会自动延迟
    // 单击判定等待双击超时，双击缩放不会误触发设置栏切换
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleSettings,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        panEnabled: _zoomed,
        scaleEnabled: true,
        maxScale: 4.0,
        child: Center(
          child: Image.network(
            widget.url,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
              ),
            ),
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white54,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
