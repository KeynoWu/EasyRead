import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book.dart';

class BookshelfList extends StatelessWidget {
  final List<Book> books;
  final void Function(Book)? onBookTap;

  const BookshelfList({super.key, required this.books, this.onBookTap});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return Card(
          child: InkWell(
            onTap: () => onBookTap?.call(book),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 48,
                      height: 64,
                      color: AppColors.separator.withOpacity(0.2),
                      child: book.coverUrl != null
                          ? Image.network(book.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.book))
                          : const Icon(Icons.book, color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(book.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        if (book.author != null)
                          Text(book.author!, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                        const SizedBox(height: 4),
                        Text(
                          book.lastChapter ?? '未开始阅读',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (book.progress > 0)
                    Text('${(book.progress * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 12, color: AppColors.tint)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
