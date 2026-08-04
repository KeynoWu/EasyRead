import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/search_result.dart';

class SearchResultItem extends StatelessWidget {
  final SearchResult result;

  const SearchResultItem({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: () {
          // Phase 2: 跳转到书籍详情页
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 64,
                  height: 88,
                  color: AppColors.separator.withOpacity(0.3),
                  child: result.coverUrl != null
                      ? Image.network(result.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.book))
                      : const Icon(Icons.book, color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(result.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    if (result.author != null)
                      Text(result.author!, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    const SizedBox(height: 4),
                    Text(result.sourceName, style: TextStyle(fontSize: 12, color: AppColors.tint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
