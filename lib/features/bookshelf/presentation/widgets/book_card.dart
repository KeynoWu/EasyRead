import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book.dart';

class BookCard extends StatelessWidget {
  final Book book;
  final void Function(Book)? onBookTap;
  final void Function(Book)? onBookLongPress;
  final bool editMode;
  final bool selected;

  const BookCard({
    super.key,
    required this.book,
    this.onBookTap,
    this.onBookLongPress,
    this.editMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onBookTap == null ? null : () => onBookTap!(book),
      onLongPress: onBookLongPress == null ? null : () => onBookLongPress!(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面
          Expanded(
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: AppColors.separator.withValues(alpha: 0.3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: book.coverUrl != null
                      ? Image.network(book.coverUrl!, fit: BoxFit.cover, cacheWidth: 240, errorBuilder: (_, _, _) => _bookPlaceholder())
                      : _bookPlaceholder(),
                ),
                if (editMode)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? AppColors.tint : Colors.black38,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Icon(
                        selected ? Icons.check : Icons.circle_outlined,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 书名
          Text(
            book.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          // 进度
          if (book.progress > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: book.progress,
                  minHeight: 3,
                  backgroundColor: AppColors.separator.withValues(alpha: 0.5),
                  color: AppColors.tint,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bookPlaceholder() {
    return const Center(
      child: Icon(Icons.auto_stories, size: 40, color: AppColors.textSecondary),
    );
  }
}
