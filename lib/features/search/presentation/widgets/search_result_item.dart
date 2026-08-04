import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/search_result.dart';

class SearchResultItem extends StatelessWidget {
  final SearchResult result;

  const SearchResultItem({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      child: InkWell(
        onTap: () {
          final alts = jsonEncode(result.alternatives.map((a) => {
            'bookId': a.bookId,
            'sourceId': a.sourceId,
            'sourceName': a.sourceName,
            'detailUrl': a.detailUrl,
          }).toList());
          context.push(
            '/reader/${Uri.encodeComponent(result.bookId)}'
            '?sourceId=${Uri.encodeComponent(result.sourceId)}'
            '&detailUrl=${Uri.encodeComponent(result.detailUrl ?? '')}'
            '&alternatives=${Uri.encodeComponent(alts)}',
          );
        },
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
