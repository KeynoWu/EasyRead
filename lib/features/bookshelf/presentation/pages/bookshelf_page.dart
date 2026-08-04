import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book.dart';
import '../../domain/usecases/import_local_book.dart';
import '../providers/bookshelf_provider.dart';
import '../widgets/bookshelf_grid.dart';
import '../widgets/bookshelf_list.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool _isGrid = true;
  String _sortMode = 'time'; // time | name | added

  Future<void> _importLocalBook() async {
    final repo = ref.read(bookshelfRepositoryProvider);
    final useCase = ImportLocalBook(repository: repo);
    final book = await useCase.fromFile();
    if (!mounted) return;
    if (book != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入《${book.name}》')),
      );
      ref.invalidate(bookshelfListProvider);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导入失败或已取消')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(bookshelfListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          // 导入本地书籍
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: _importLocalBook,
            tooltip: '导入本地书籍',
          ),
          // 排序菜单
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            onSelected: (value) => setState(() => _sortMode = value),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'time', child: Text('按阅读时间')),
              const PopupMenuItem(value: 'name', child: Text('按书名')),
              const PopupMenuItem(value: 'added', child: Text('按加入时间')),
            ],
          ),
          // 视图切换
          IconButton(
            icon: Icon(_isGrid ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() => _isGrid = !_isGrid),
            tooltip: _isGrid ? '切换为列表' : '切换为网格',
          ),
        ],
      ),
      body: booksAsync.when(
        data: (books) {
          final sorted = _sortBooks(books);
          if (sorted.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.auto_stories, size: 64, color: AppColors.textSecondary.withValues(alpha: 0.4)),
                  const SizedBox(height: 16),
                  const Text('书架空空', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text('去搜索添加书籍，或导入本地 TXT/EPUB', style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _importLocalBook,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('导入本地书籍'),
                  ),
                ],
              ),
            );
          }
          return _isGrid
              ? BookshelfGrid(books: sorted)
              : BookshelfList(books: sorted);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  List<Book> _sortBooks(List<Book> books) {
    final list = List.of(books);
    switch (_sortMode) {
      case 'name':
        list.sort((a, b) => a.name.compareTo(b.name));
        break;
      case 'added':
        break;
      case 'time':
      default:
        list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
        break;
    }
    return list;
  }
}
