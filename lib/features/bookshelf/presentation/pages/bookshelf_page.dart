import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/bookshelf_provider.dart';
import '../widgets/bookshelf_grid.dart';

class BookshelfPage extends ConsumerWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(bookshelfListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('书架')),
      body: booksAsync.when(
        data: (books) => books.isEmpty
            ? const Center(child: Text('书架空空，去搜索添加书籍吧'))
            : BookshelfGrid(books: books),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}
