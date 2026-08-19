import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/reader_provider.dart';

/// 章节目录面板 — 打开时自动滚动到当前章节；目录加载失败可重试
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
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '章节目录',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: catalog == null
                    ? _buildCatalogError(notifier)
                    : catalog.chapters.isEmpty
                    ? const Center(child: Text('暂无目录'))
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
                                color: isCurrent ? Colors.blue : null,
                              ),
                            ),
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

  Widget _buildCatalogError(ReaderNotifier notifier) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            color: AppColors.textSecondary,
            size: 40,
          ),
          const SizedBox(height: 12),
          const Text(
            '目录加载失败',
            style: TextStyle(color: AppColors.textSecondary),
          ),
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
