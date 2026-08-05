import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../bookshelf/domain/entities/book.dart';
import '../../../bookshelf/presentation/providers/bookshelf_provider.dart';
import '../../domain/entities/search_result.dart';

class SearchResultItem extends ConsumerStatefulWidget {
  final SearchResult result;

  const SearchResultItem({super.key, required this.result});

  @override
  ConsumerState<SearchResultItem> createState() => _SearchResultItemState();
}

class _SearchResultItemState extends ConsumerState<SearchResultItem> {
  bool _busy = false;

  Future<void> _openReader() async {
    if (_busy) return;
    _busy = true;
    final result = widget.result;
    try {
      final alts = jsonEncode(result.alternatives.map((a) => {
        'bookId': a.bookId,
        'sourceId': a.sourceId,
        'sourceName': a.sourceName,
        'detailUrl': a.detailUrl,
      }).toList());
      await ref.read(bookshelfRepositoryProvider).save(Book(
        id: result.bookId,
        name: result.name,
        author: result.author,
        coverUrl: result.coverUrl,
        sourceId: result.sourceId,
        lastReadAt: DateTime.now(),
      ));
      await ref.read(bookDetailServiceProvider).save(
        result.bookId,
        detailUrl: result.detailUrl,
        alternativesJson: alts,
      );
      ref.invalidate(bookshelfListProvider);
      if (!mounted) return;
      context.push(
        '/reader/${Uri.encodeComponent(result.bookId)}'
        '?sourceId=${Uri.encodeComponent(result.sourceId)}'
        '&detailUrl=${Uri.encodeComponent(result.detailUrl ?? '')}'
        '&alternatives=${Uri.encodeComponent(alts)}',
      );
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
                        // 多源指示
                        if (result.alternatives.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark ? AppColors.darkSeparator : AppColors.separator.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '+${result.alternatives.length} 源',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
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
