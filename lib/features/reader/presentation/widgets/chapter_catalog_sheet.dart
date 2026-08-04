import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/reader_provider.dart';

/// 章节目录面板
class ChapterCatalogSheet extends ConsumerWidget {
  const ChapterCatalogSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);
    final catalog = state.catalog;
    final currentChapter = state.currentChapter;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('章节目录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              const Divider(height: 1),
              Expanded(
                child: catalog == null || catalog.chapters.isEmpty
                    ? const Center(child: Text('暂无目录'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: catalog.chapters.length,
                        itemBuilder: (context, index) {
                          final item = catalog.chapters[index];
                          final isCurrent = currentChapter != null && currentChapter.index == index;
                          return ListTile(
                            dense: true,
                            selected: isCurrent,
                            title: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
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
}
