import 'package:flutter/material.dart';
import '../../domain/entities/book.dart';
import 'book_card.dart';

class BookshelfGrid extends StatelessWidget {
  final List<Book> books;
  final void Function(Book)? onBookTap;

  const BookshelfGrid({super.key, required this.books, this.onBookTap});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
        childAspectRatio: 0.65,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) => BookCard(
        book: books[index],
        onTap: () => onBookTap?.call(books[index]),
      ),
    );
  }
}
