import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book.dart';

class BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;

  const BookCard({super.key, required this.book, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                color: AppColors.separator.withValues(alpha: 0.2),
                child: book.coverUrl != null
                    ? Image.network(book.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.book, size: 40))
                    : const Icon(Icons.book, size: 40, color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          if (book.progress > 0)
            LinearProgressIndicator(
              value: book.progress,
              backgroundColor: AppColors.separator.withValues(alpha: 0.3),
              color: AppColors.tint,
            ),
        ],
      ),
    );
  }
}
