import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book.dart';
import '../../domain/usecases/import_local_book.dart';
import '../../domain/usecases/manage_book_group.dart';
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
  String? _selectedGroup; // null = 全部
  bool _editMode = false;
  final Set<String> _selectedIds = {};

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

  void _toggleEditMode() {
    setState(() {
      _editMode = !_editMode;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要删除选中的 ${_selectedIds.length} 本书吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final repo = ref.read(bookshelfRepositoryProvider);
    await repo.deleteAll(_selectedIds.toList());
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
    ref.invalidate(bookshelfListProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除')),
      );
    }
  }

  Future<void> _moveToGroup() async {
    if (_selectedIds.isEmpty) return;
    final books = await ref.read(bookshelfRepositoryProvider).getAll();
    final groupManager = ManageBookGroup(repository: ref.read(bookshelfRepositoryProvider));
    final groups = groupManager.getAllGroups(books);
    if (!mounted) return;

    final group = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('移动到分组'),
        children: [
          for (final g in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, g),
              child: Text(g),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('不分组', style: TextStyle(color: AppColors.textSecondary)),
          ),
        ],
      ),
    );

    if (!mounted) return;
    final repo = ref.read(bookshelfRepositoryProvider);
    for (final id in _selectedIds) {
      final book = await repo.getById(id);
      if (book != null) {
        await repo.save(Book(
          id: book.id,
          name: book.name,
          author: book.author,
          coverUrl: book.coverUrl,
          sourceId: book.sourceId,
          lastChapter: book.lastChapter,
          progress: book.progress,
          group: group,
          lastReadAt: book.lastReadAt,
        ));
      }
    }
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
    ref.invalidate(bookshelfListProvider);
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(bookshelfListProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_editMode ? '已选择 ${_selectedIds.length} 本' : '书架'),
        actions: [
          if (_editMode) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
              tooltip: '删除选中',
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: _selectedIds.isEmpty ? null : _moveToGroup,
              tooltip: '移动到分组',
            ),
          ],
          IconButton(
            icon: Icon(_editMode ? Icons.close : Icons.checklist),
            onPressed: _toggleEditMode,
            tooltip: _editMode ? '退出编辑' : '批量管理',
          ),
          if (!_editMode) ...[
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              onPressed: _importLocalBook,
              tooltip: '导入本地书籍',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              onSelected: (value) => setState(() => _sortMode = value),
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'time', child: Text('按阅读时间')),
                const PopupMenuItem(value: 'name', child: Text('按书名')),
                const PopupMenuItem(value: 'added', child: Text('按加入时间')),
              ],
            ),
            IconButton(
              icon: Icon(_isGrid ? Icons.view_list : Icons.grid_view),
              onPressed: () => setState(() => _isGrid = !_isGrid),
              tooltip: _isGrid ? '切换为列表' : '切换为网格',
            ),
          ],
        ],
      ),
      body: booksAsync.when(
        data: (books) {
          final sorted = _sortBooks(books);
          final filtered = _selectedGroup == null
              ? sorted
              : ManageBookGroup(repository: ref.read(bookshelfRepositoryProvider))
                  .filterByGroup(sorted, _selectedGroup);
          return Column(
            children: [
              if (!_editMode) _buildGroupFilter(books),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.auto_stories, size: 64, color: AppColors.tint.withValues(alpha: 0.5)),
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
                      )
                    : _isGrid
                        ? BookshelfGrid(
                            books: filtered,
                            editMode: _editMode,
                            selectedIds: _selectedIds,
                            onBookTap: _editMode ? (b) => _toggleSelect(b.id) : null,
                          )
                        : BookshelfList(
                            books: filtered,
                            editMode: _editMode,
                            selectedIds: _selectedIds,
                            onBookTap: _editMode ? (b) => _toggleSelect(b.id) : null,
                          ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Widget _buildGroupFilter(List<Book> books) {
    final groups = ManageBookGroup(repository: ref.read(bookshelfRepositoryProvider))
        .getAllGroups(books);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          _buildFilterChip('全部', _selectedGroup == null, () => setState(() => _selectedGroup = null)),
          for (final group in groups)
            _buildFilterChip(group, _selectedGroup == group, () => setState(() => _selectedGroup = group)),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, bool selected, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        selectedColor: AppColors.tint,
        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? Colors.white : (isDark ? AppColors.darkTextPrimary : AppColors.textPrimary),
        ),
        side: BorderSide(
          color: selected ? AppColors.tint : AppColors.separator,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
