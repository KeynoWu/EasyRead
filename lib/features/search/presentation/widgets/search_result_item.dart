import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/search_result.dart';

class SearchResultItem extends ConsumerStatefulWidget {
  final SearchResult result;

  const SearchResultItem({super.key, required this.result});

  @override
  ConsumerState<SearchResultItem> createState() => _SearchResultItemState();
}

class _SearchResultItemState extends ConsumerState<SearchResultItem> {
  bool _busy = false;

  /// 以指定源打开阅读器（[source] 为空用主源；否则用替代源）
  Future<void> _openReader({SourceOption? source}) async {
    if (_busy) return;
    _busy = true;
    final result = widget.result;
    final detailResult = source == null
        ? result
        : SearchResult(
            bookId: source.bookId,
            name: result.name,
            author: result.author,
            coverUrl: result.coverUrl,
            detailUrl: source.detailUrl,
            intro: result.intro,
            kind: result.kind,
            lastChapter: result.lastChapter,
            wordCount: result.wordCount,
            sourceId: source.sourceId,
            sourceName: source.sourceName,
            alternatives: result.alternatives,
          );
    try {
      if (!mounted) return;
      await context.push('/book-detail', extra: detailResult);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加入书架失败，请重试')),
        );
      }
    } finally {
      _busy = false;
    }
  }

  /// 弹出替代书源列表，选中后以该源直接打开
  Future<void> _showSourcePicker() async {
    final result = widget.result;
    final selected = await showModalBottomSheet<SourceOption>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '选择书源 — ${result.name}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.check, color: AppColors.tint, size: 20),
                    title: Text(result.sourceName, style: const TextStyle(fontSize: 14)),
                    subtitle: const Text('当前书源', style: TextStyle(fontSize: 12)),
                    onTap: () => Navigator.pop(context),
                  ),
                  for (final alt in result.alternatives)
                    ListTile(
                      leading: const Icon(Icons.swap_horiz, color: AppColors.tint, size: 20),
                      title: Text(alt.sourceName, style: const TextStyle(fontSize: 14)),
                      subtitle: const Text('点击以此书源打开', style: TextStyle(fontSize: 12)),
                      onTap: () => Navigator.pop(context, alt),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      await _openReader(source: selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      child: InkWell(
        onTap: _openReader,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // 封面
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 60,
                  height: 84,
                  color: AppColors.separator.withValues(alpha: 0.3),
                  child: result.coverUrl != null
                      ? Image.network(result.coverUrl!, fit: BoxFit.cover, cacheWidth: 180, errorBuilder: (_, _, _) => const Icon(Icons.auto_stories, color: AppColors.textSecondary))
                      : const Icon(Icons.auto_stories, color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(width: 12),
              // 信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
                      ),
                    ),
                    if (result.author != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          result.author!,
                          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                        ),
                      ),
                    if (result.kind != null || result.lastChapter != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          [
                            if (result.kind != null) result.kind!,
                            if (result.lastChapter != null) result.lastChapter!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        // 书源徽标
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.tintSoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            result.sourceName,
                            style: const TextStyle(fontSize: 11, color: AppColors.tint),
                          ),
                        ),
                        // 多源指示：点击弹出换源列表
                        if (result.alternatives.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: _showSourcePicker,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isDark ? AppColors.darkSeparator : AppColors.separator.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '+${result.alternatives.length} 源',
                                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                  ),
                                  const SizedBox(width: 2),
                                  const Icon(Icons.arrow_drop_down, size: 14, color: AppColors.textSecondary),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
