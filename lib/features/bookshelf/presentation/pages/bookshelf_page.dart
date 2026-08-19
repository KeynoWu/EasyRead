import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/router/app_router.dart' show ReaderRouteArgs;
import '../../../../core/theme/app_colors.dart';
import '../../../../features/book_source/presentation/providers/book_source_provider.dart';
import '../../../../features/search/domain/entities/search_result.dart';
import '../../data/services/book_detail_service.dart';
import '../../../reader/data/models/reading_progress_model.dart';
import '../../../reader/data/services/book_cache_service.dart';
import '../../../reader/presentation/providers/reader_provider.dart';
import '../../domain/entities/book.dart';
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
  String _sortMode = 'time'; // time | name | author | added
  String? _selectedGroup; // null = 全部
  bool _editMode = false;
  bool _refreshingAll = false;
  bool _showSearch = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedIds = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 排序/分组结果缓存：key 为 (books 集合, sortMode, 分组)，
  /// 数据或筛选条件未变时复用，避免编辑模式每次勾选触发全量重排
  List<Book>? _cachedSorted;
  List<Book>? _cachedFiltered;
  String? _cachedViewKey;

  Future<void> _refreshBookshelf() async {
    ref.invalidate(bookshelfListProvider);
    await ref.read(bookshelfListProvider.future);
  }

  /// 打开书籍阅读（续读上次进度）
  Future<void> _openReader(Book book) async {
    final detail = await ref.read(bookDetailServiceProvider).get(book.id);
    if (!mounted) return;
    final sourceId = book.sourceId;
    final detailUrl = detail?.detailUrl;
    final alternatives = detail?.alternativesJson;
    final variables = detail?.variablesJson;
    context.push(
      '/reader/${Uri.encodeComponent(book.id)}',
      extra: ReaderRouteArgs(
        bookId: book.id,
        sourceId: sourceId,
        detailUrl: detailUrl,
        alternativesJson: alternatives,
        variablesJson: variables,
      ),
    );
  }

  Future<void> _showBookActions(Book book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('查看详情'),
              subtitle: const Text('简介 / 目录 / 换源'),
              onTap: () => Navigator.pop(context, 'detail'),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('更新书籍详情'),
              onTap: () => Navigator.pop(context, 'refresh'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清除本书缓存'),
              onTap: () => Navigator.pop(context, 'clearCache'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'detail':
        await _openBookDetail(book);
      case 'refresh':
        await _refreshBookDetail(book);
      case 'clearCache':
        await _clearBookCache(book);
    }
  }

  /// 从书架打开书籍详情页（简介/目录/换源/导出）
  Future<void> _openBookDetail(Book book) async {
    final detail = await ref.read(bookDetailServiceProvider).get(book.id);
    if (!mounted) return;
    String? sourceName;
    try {
      final source = book.sourceId == null
          ? null
          : await ref
              .read(bookSourceRepositoryProvider)
              .getById(book.sourceId!);
      sourceName = source?.name;
    } catch (_) {
      // 查询失败用兜底文案
    }
    if (!mounted) return;
    context.push(
      '/book-detail',
      extra: SearchResult(
        bookId: book.id,
        name: book.name,
        author: book.author,
        coverUrl: book.coverUrl,
        detailUrl: detail?.detailUrl,
        sourceId: book.sourceId ?? 'default',
        sourceName: sourceName ?? '未知书源',
        lastChapter: book.lastChapter,
        alternatives: _decodeAlternatives(detail?.alternativesJson),
        variables: BookDetail.decodeVariables(detail?.variablesJson),
      ),
    );
  }

  /// 解析替代书源 JSON（书架缓存格式与搜索结果的 alternatives 相同）
  List<SourceOption> _decodeAlternatives(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final list = jsonDecode(json) as List;
      return [
        for (final e in list)
          if (e is Map)
            SourceOption(
              bookId: e['bookId']?.toString() ?? '',
              sourceId: e['sourceId']?.toString() ?? '',
              sourceName: e['sourceName']?.toString() ?? '未知书源',
              detailUrl: e['detailUrl']?.toString(),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _refreshBookDetail(Book book, {bool showFeedback = true}) async {
    final sourceId = book.sourceId;
    if (sourceId == null) return;
    final detail = await ref.read(bookDetailServiceProvider).get(book.id);
    final detailUrl = detail?.detailUrl;
    if (detailUrl == null || detailUrl.isEmpty) return;
    try {
      final fetched = await ref
          .read(readerRepositoryProvider)
          .getBookDetail(
            bookId: book.id,
            sourceId: sourceId,
            detailUrl: detailUrl,
            variables: BookDetail.decodeVariables(detail?.variablesJson),
          );
      await ref.read(bookshelfRepositoryProvider).save(Book(
        id: book.id,
        name: fetched.name ?? book.name,
        author: fetched.author ?? book.author,
        coverUrl: fetched.coverUrl ?? book.coverUrl,
        sourceId: sourceId,
        lastChapter: fetched.lastChapter ?? book.lastChapter,
        progress: book.progress,
        group: book.group,
        lastReadAt: book.lastReadAt,
      ));
      ref.invalidate(bookshelfListProvider);
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书籍详情已更新')),
        );
      }
    } catch (_) {
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('更新失败，请检查网络或书源规则')),
        );
      }
    }
  }

  Future<void> _refreshAllBooks() async {
    if (_refreshingAll) return;
    setState(() => _refreshingAll = true);
    final repo = ref.read(bookshelfRepositoryProvider);
    final books = await repo.getAll();
    final candidates = books.where((b) => b.sourceId != null).toList();
    // 分批并发（每批 4 个），避免大批量书籍请求风暴
    const batchSize = 4;
    for (var i = 0; i < candidates.length; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize);
      await Future.wait(
        batch.map((b) => _refreshBookDetail(b, showFeedback: false)),
      );
    }
    if (!mounted) return;
    setState(() => _refreshingAll = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已尝试更新全部书籍详情（${candidates.length} 本）')),
    );
  }

  Future<void> _clearBookCache(Book book) async {
    await ref.read(readerRepositoryProvider).clearBookCache(book.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本书缓存已清除')),
    );
  }

  void _toggleEditMode() {
    setState(() {
      _editMode = !_editMode;
      _selectedIds.clear();
    });
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchQuery = '';
        _searchController.clear();
      }
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

  /// 清理某本书的整本缓存（含章节内容与元数据）
  Future<void> _clearBookCacheFor(String bookId) async {
    final box = await BookCacheBox.open();
    final keys = box.keys
        .where((k) => k.toString() == '__meta_$bookId' || k.toString().startsWith('$bookId|'))
        .toList();
    if (keys.isNotEmpty) {
      await box.deleteAll(keys);
    }
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final repo = ref.read(bookshelfRepositoryProvider);
    await repo.deleteAll(_selectedIds.toList());
    final detailService = ref.read(bookDetailServiceProvider);
    // 删除书籍时同步清理章节缓存与阅读进度，避免残留数据占用磁盘或错位续读
    final readerRepo = ref.read(readerRepositoryProvider);
    final progressBox = await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
    for (final id in _selectedIds) {
      await detailService.remove(id);
      await readerRepo.clearBookCache(id);
      await progressBox.delete(id);
      // 清理整本缓存（book_cache），避免孤儿数据残留磁盘
      await _clearBookCacheFor(id);
    }
    if (!mounted) return;
    setState(() {
      _editMode = false;
      _selectedIds.clear();
    });
    ref.invalidate(bookshelfListProvider);
    if (mounted) {
      HapticFeedback.mediumImpact();
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
    for (final id in _selectedIds) {
      await groupManager.setGroup(id, group);
    }
    if (!mounted) return;
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
              icon: Icon(_showSearch ? Icons.close : Icons.search),
              onPressed: _toggleSearch,
              tooltip: '搜索书架',
            ),
            IconButton(
              icon: _refreshingAll
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: _refreshingAll ? null : _refreshAllBooks,
              tooltip: '更新全部详情',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              onSelected: (value) => setState(() => _sortMode = value),
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'time', child: Text('按阅读时间')),
                const PopupMenuItem(value: 'name', child: Text('按书名')),
                const PopupMenuItem(value: 'author', child: Text('按作者')),
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
      body: Column(
        children: [
          Expanded(
            child: booksAsync.when(
              data: (books) {
                final viewKey = '${identityHashCode(books)}|$_sortMode|$_selectedGroup|$_searchQuery';
                List<Book> sorted;
                List<Book> filtered;
                if (_cachedViewKey == viewKey) {
                  sorted = _cachedSorted!;
                  filtered = _cachedFiltered!;
                } else {
                  sorted = _sortBooks(books);
                  filtered = _selectedGroup == null
                      ? sorted
                      : ManageBookGroup(repository: ref.read(bookshelfRepositoryProvider))
                          .filterByGroup(sorted, _selectedGroup);
                  final query = _searchQuery.trim();
                  filtered = query.isEmpty
                      ? filtered
                      : filtered
                          .where((book) =>
                              book.name.contains(query) ||
                              (book.author ?? '').contains(query))
                          .toList();
                  _cachedSorted = sorted;
                  _cachedFiltered = filtered;
                  _cachedViewKey = viewKey;
                }
                return Column(
                  children: [
                    if (_showSearch)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) => setState(() {
                            _searchQuery = value;
                            _cachedViewKey = null;
                          }),
                          decoration: const InputDecoration(
                            hintText: '搜索书名或作者',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    if (!_editMode) _buildGroupFilter(books),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _refreshBookshelf,
                        child: filtered.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  const SizedBox(height: 120),
                                  Icon(Icons.auto_stories, size: 64, color: AppColors.tint.withValues(alpha: 0.5)),
                                  const SizedBox(height: 16),
                                  const Text('书架空空', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 8),
                                  const Text('去搜索添加书籍', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                                ],
                              )
                            : _isGrid
                                ? BookshelfGrid(
                                    books: filtered,
                                    editMode: _editMode,
                                    selectedIds: _selectedIds,
                                    onBookTap: _editMode ? (b) => _toggleSelect(b.id) : _openReader,
                                    onBookLongPress: _editMode ? null : _showBookActions,
                                  )
                                : BookshelfList(
                                    books: filtered,
                                    editMode: _editMode,
                                    selectedIds: _selectedIds,
                                    onBookTap: _editMode ? (b) => _toggleSelect(b.id) : _openReader,
                                    onBookLongPress: _editMode ? null : _showBookActions,
                                  ),
                      ),
                    ),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
            ),
          ),
        ],
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
      case 'author':
        list.sort((a, b) => (a.author ?? '').compareTo(b.author ?? ''));
        break;
      case 'added':
        // 本地导入的书籍 id 为创建时间戳；其他来源按最早时间兜底
        list.sort((a, b) => _addedTime(b).compareTo(_addedTime(a)));
        break;
      case 'time':
      default:
        list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
        break;
    }
    return list;
  }

  DateTime _addedTime(Book book) {
    final ts = int.tryParse(book.id);
    if (ts != null) return DateTime.fromMillisecondsSinceEpoch(ts);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
