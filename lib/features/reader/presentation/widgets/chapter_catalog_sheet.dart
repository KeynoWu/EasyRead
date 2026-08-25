import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/reader_provider.dart';

/// 章节目录面板 — 打开时自动滚动到当前章节；目录加载失败可重试。
/// 视觉与正文明确区分：面板用独立的 surface 底色（浅色=白卡、深色=深灰），
/// 当前章节以琥珀色高亮，不再复用阅读主题背景导致"目录像另一页正文"。
class ChapterCatalogSheet extends ConsumerStatefulWidget {
  const ChapterCatalogSheet({super.key});

  @override
  ConsumerState<ChapterCatalogSheet> createState() =>
      _ChapterCatalogSheetState();
}

class _ChapterCatalogSheetState extends ConsumerState<ChapterCatalogSheet> {
  /// 固定行高（dense ListTile）：用于打开时定位当前章节
  static const double _itemExtent = 48;
  bool _scrolledToCurrent = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);
    final catalog = state.catalog;
    final currentChapter = state.currentChapter;

    // 面板配色：跟随阅读主题明暗，但与正文背景拉开层次
    final isDark =
        state.theme.backgroundColor.computeLuminance() < 0.5;
    final surfaceBg = isDark ? AppColors.darkSurface : AppColors.surface;
    final primaryFg =
        isDark ? AppColors.darkTextPrimary : AppColors.textPrimary;
    final secondaryFg =
        isDark ? AppColors.darkTextSecondary : AppColors.textSecondary;
    final accent = isDark ? AppColors.darkTint : AppColors.tint;
    final divider = isDark ? AppColors.darkSeparator : AppColors.separator;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        // 打开时定位到当前章节（仅一次；builder 随拖动重建，标志防重复）
        if (!_scrolledToCurrent && currentChapter != null && catalog != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _scrolledToCurrent) return;
            _scrolledToCurrent = true;
            if (scrollController.hasClients) {
              scrollController.jumpTo(
                (currentChapter.index * _itemExtent).clamp(
                  0.0,
                  scrollController.position.maxScrollExtent,
                ),
              );
            }
          });
        }

        return Container(
          decoration: BoxDecoration(
            color: surfaceBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '章节目录',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: primaryFg,
                  ),
                ),
              ),
              Divider(height: 1, color: divider),
              Expanded(
                child: catalog == null
                    ? _buildCatalogError(notifier, secondaryFg)
                    : catalog.chapters.isEmpty
                    ? Center(
                        child: Text('暂无目录', style: TextStyle(color: secondaryFg)),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemExtent: _itemExtent,
                        itemCount: catalog.chapters.length,
                        itemBuilder: (context, index) {
                          final item = catalog.chapters[index];
                          final isCurrent = currentChapter != null &&
                              currentChapter.index == index;
                          return ListTile(
                            dense: true,
                            selected: isCurrent,
                            title: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: isCurrent ? accent : primaryFg,
                              ),
                            ),
                            trailing: isCurrent
                                ? Icon(Icons.play_arrow, size: 18, color: accent)
                                : null,
                            onTap: () {
                              Navigator.pop(context);
                              notifier.jumpToChapter(index);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCatalogError(ReaderNotifier notifier, Color fg) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: fg, size: 40),
          const SizedBox(height: 12),
          Text('目录加载失败', style: TextStyle(color: fg)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: notifier.reloadCatalog,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
