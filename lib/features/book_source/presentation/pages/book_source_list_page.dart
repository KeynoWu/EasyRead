import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/data/cookie_jar_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/entities/book_source_test_record.dart';
import '../providers/book_source_provider.dart';
import '../widgets/book_source_card.dart';

/// 书源筛选维度
enum SourceFilter {
  all('全部'),
  usable('可用'),
  slow('较慢'),
  unusable('不可用'),
  untested('未检测');

  final String label;
  const SourceFilter(this.label);
}

class BookSourceListPage extends ConsumerStatefulWidget {
  const BookSourceListPage({super.key});

  @override
  ConsumerState<BookSourceListPage> createState() => _BookSourceListPageState();
}

class _BookSourceListPageState extends ConsumerState<BookSourceListPage> {
  final Set<String> _pendingToggles = {};
  SourceFilter _filter = SourceFilter.all;
  String? _groupFilter;
  bool _sortBySpeed = false;
  bool _showSearch = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // 多选管理
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};
  bool _bulkBusy = false;

  /// 当前筛选下的可见书源 id（build 时更新，供全选使用）
  List<String> _visibleIds = const [];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  Future<void> _openEditor({String? sourceId}) async {
    final repo = ref.read(bookSourceRepositoryProvider);
    final source = sourceId != null ? await repo.getById(sourceId) : null;
    if (!mounted) return;
    final changed = await context.push<bool>('/book-source/edit', extra: source);
    if (changed == true) {
      // 书源规则可能已修改，旧检测结果失效，清除待重测
      if (sourceId != null) {
        await ref.read(bookSourceTestStoreProvider).remove(sourceId);
        ref.invalidate(bookSourceTestRecordsProvider);
      }
      ref.invalidate(bookSourceListProvider);
    }
  }

  Future<void> _showSourceMenu(BookSource source) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制书源 JSON'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            if ((source.loginUrl?.isNotEmpty ?? false) ||
                (source.bookSourceUrl?.isNotEmpty ?? false))
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('登录书源'),
                subtitle: const Text('WebView 登录并保存 Cookie'),
                onTap: () => Navigator.pop(context, 'login'),
              ),
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('规则测试'),
              subtitle: const Text('实时调试 CSS/JSONPath/JS/模板规则'),
              onTap: () => Navigator.pop(context, 'ruleTester'),
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('进入多选'),
              onTap: () => Navigator.pop(context, 'select'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        final json = jsonEncode({
          'bookSourceName': source.name,
          'bookSourceGroup': source.bookSourceGroup,
          'bookSourceUrl': source.bookSourceUrl,
          'enabled': source.enabled,
          ...source.rules,
        });
        await Clipboard.setData(ClipboardData(text: json));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书源 JSON 已复制')),
        );
      case 'select':
        _enterSelection(source);
      case 'login':
        final success = await context.push<bool>('/book-source/login', extra: source);
        if (success == true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录 Cookie 已保存')),
          );
        }
      case 'ruleTester':
        await context.push('/book-source/rule-tester', extra: source);
    }
  }

  Future<void> _toggleSource(BookSource source) async {
    if (_pendingToggles.contains(source.id)) return;
    _pendingToggles.add(source.id);
    try {
      final repo = ref.read(bookSourceRepositoryProvider);
      await repo.save(source.copyWith(enabled: !source.enabled));
      ref.invalidate(bookSourceListProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书源状态更新失败')),
        );
      }
    } finally {
      _pendingToggles.remove(source.id);
    }
  }

  /// 长按进入多选模式
  void _enterSelection(BookSource source) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(source.id);
    });
  }

  /// 进入多选模式并自动全选当前筛选分类下的所有源：
  /// 一键批量关闭/删除某一类（如"不可用"）书源的入口
  void _enterBulkForCurrentFilter() {
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..addAll(_visibleIds);
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  /// 批量设置启用状态（可用 = 恢复/禁用）
  Future<void> _bulkSetEnabled(bool enabled) async {
    if (_selectedIds.isEmpty || _bulkBusy) return;
    setState(() => _bulkBusy = true);
    try {
      final repo = ref.read(bookSourceRepositoryProvider);
      final sources = await repo.getAll();
      for (final source in sources.where((s) => _selectedIds.contains(s.id))) {
        if (source.enabled != enabled) {
          await repo.save(source.copyWith(enabled: enabled));
        }
      }
      ref.invalidate(bookSourceListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已${enabled ? '启用' : '禁用'} ${_selectedIds.length} 个书源')),
        );
        _exitSelection();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('批量操作失败')),
        );
      }
    } finally {
      setState(() => _bulkBusy = false);
    }
  }

  /// 批量删除（带确认）
  Future<void> _bulkDelete() async {
    if (_selectedIds.isEmpty || _bulkBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书源'),
        content: Text('确定删除选中的 ${_selectedIds.length} 个书源吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _bulkBusy = true);
    try {
      final repo = ref.read(bookSourceRepositoryProvider);
      final store = ref.read(bookSourceTestStoreProvider);
      final cookieJar = CookieJarService();
      for (final id in _selectedIds) {
        await repo.delete(id);
        await store.remove(id);
        await cookieJar.remove(id);
      }
      ref.invalidate(bookSourceListProvider);
      ref.invalidate(bookSourceTestRecordsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除 ${_selectedIds.length} 个书源')),
        );
        _exitSelection();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败')),
        );
      }
    } finally {
      setState(() => _bulkBusy = false);
    }
  }

  /// 打开批量检测页，返回后刷新检测结果
  Future<void> _openTestPage() async {
    await context.push<bool>('/book-source/test');
    if (mounted) {
      ref.invalidate(bookSourceTestRecordsProvider);
    }
  }

  Future<void> _refreshSources() async {
    ref.invalidate(bookSourceListProvider);
    ref.invalidate(bookSourceTestRecordsProvider);
    await Future.wait([
      ref.read(bookSourceListProvider.future),
      ref.read(bookSourceTestRecordsProvider.future),
    ]);
  }

  /// 应用筛选 + 排序
  List<BookSource> _applyView(
    List<BookSource> sources,
    Map<String, BookSourceTestRecord> records,
  ) {
    var result = sources.where((s) {
      final query = _searchQuery.trim();
      if (query.isNotEmpty &&
          !s.name.contains(query) &&
          !(s.bookSourceGroup ?? '').contains(query)) {
        return false;
      }
      if (_groupFilter != null && s.bookSourceGroup != _groupFilter) {
        return false;
      }
      final record = records[s.id];
      switch (_filter) {
        case SourceFilter.all:
          return true;
        case SourceFilter.usable:
          return record?.usable ?? false;
        case SourceFilter.slow:
          return (record?.usable ?? false) && (record?.isSlow ?? false);
        case SourceFilter.unusable:
          return record != null && !record.usable;
        case SourceFilter.untested:
          return record == null;
      }
    }).toList();

    if (_sortBySpeed) {
      result.sort((a, b) {
        final ra = records[a.id];
        final rb = records[b.id];
        if (ra == null && rb == null) return 0;
        if (ra == null) return 1; // 未检测排后
        if (rb == null) return -1;
        return ra.responseTimeMs.compareTo(rb.responseTimeMs);
      });
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(bookSourceListProvider);
    final recordsAsync = ref.watch(bookSourceTestRecordsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode ? '已选 ${_selectedIds.length} 个' : '书源管理'),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        actions: _selectionMode
            ? [
                TextButton(
                  onPressed: () {
                    // 全选/取消全选（基于当前筛选下的可见列表）
                    final visible = _visibleIds;
                    setState(() {
                      if (visible.isNotEmpty &&
                          _selectedIds.containsAll(visible)) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds
                          ..clear()
                          ..addAll(visible);
                      }
                    });
                  },
                  child: const Text('全选'),
                ),
              ]
            : [
                IconButton(
                  icon: Icon(_showSearch ? Icons.close : Icons.search),
                  onPressed: _toggleSearch,
                  tooltip: '搜索书源',
                ),
                IconButton(
                  icon: const Icon(Icons.rule_folder_outlined),
                  onPressed: _openTestPage,
                  tooltip: '批量检测',
                ),
                IconButton(
                  icon: const Icon(Icons.rss_feed),
                  onPressed: () => context.push('/book-source/subscription'),
                  tooltip: '书源订阅',
                ),
                IconButton(
                  icon: const Icon(Icons.science_outlined),
                  onPressed: () => context.push('/book-source/rule-tester'),
                  tooltip: '规则测试',
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _openEditor(),
                  tooltip: '新建书源',
                ),
              ],
      ),
      body: sourcesAsync.when(
        data: (sources) => recordsAsync.when(
          data: (records) {
            final view = _applyView(sources, records);
            _visibleIds = [for (final s in view) s.id];
            return Column(
              children: [
                if (_showSearch)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) => setState(() => _searchQuery = value),
                      decoration: const InputDecoration(
                        hintText: '搜索书源名称或分组',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                if (!_selectionMode) _buildFilterBar(sources, isDark, records),
                Expanded(
                  child: view.isEmpty
                      ? const Center(
                          child: Text('没有符合条件的书源',
                              style: TextStyle(color: AppColors.textSecondary)),
                        )
                      : RefreshIndicator(
                          onRefresh: _refreshSources,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: view.length,
                            itemBuilder: (context, index) {
                              final source = view[index];
                              return BookSourceCard(
                                source: source,
                                testRecord: records[source.id],
                                selectionMode: _selectionMode,
                                selected: _selectedIds.contains(source.id),
                                onTap: _selectionMode
                                    ? () => _toggleSelected(source.id)
                                    : () => _openEditor(sourceId: source.id),
                                onLongPress: () => _enterSelection(source),
                                onMore: _selectionMode ? null : () => _showSourceMenu(source),
                                onToggle: () => _toggleSource(source),
                              );
                            },
                          ),
                        ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载检测结果失败: $e')),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      bottomNavigationBar: _selectionMode ? _buildBulkBar() : null,
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton(
              onPressed: () => context.pushNamed('bookSourceImport'),
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildFilterBar(
    List<BookSource> sources,
    bool isDark,
    Map<String, BookSourceTestRecord> records,
  ) {
    final groups = <String>{
      for (final source in sources)
        if (source.bookSourceGroup != null) source.bookSourceGroup!,
    }.toList()
      ..sort();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final filter in SourceFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(filter.label),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() {
                          // 切换筛选退出多选：避免已选 ID 作用于不可见的源
                          _filter = filter;
                          _selectionMode = false;
                          _selectedIds.clear();
                        }),
                        labelStyle: TextStyle(
                          fontSize: 12,
                          color: _filter == filter
                              ? AppColors.tint
                              : AppColors.textSecondary,
                        ),
                        selectedColor: AppColors.tintSoft,
                        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
                        side: const BorderSide(color: AppColors.separator),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String?>(
            icon: Icon(
              _groupFilter == null ? Icons.filter_alt_outlined : Icons.filter_alt,
              size: 18,
              color: _groupFilter == null ? AppColors.textSecondary : AppColors.tint,
            ),
            tooltip: '按分组筛选',
            onSelected: (value) {
              setState(() {
                _groupFilter = value;
                _selectionMode = false;
                _selectedIds.clear();
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String?>(
                value: null,
                child: Text('全部分组'),
              ),
              for (final group in groups)
                PopupMenuItem<String?>(
                  value: group,
                  child: Text(group),
                ),
            ],
          ),
          InkWell(
            onTap: () => setState(() => _sortBySpeed = !_sortBySpeed),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  Icon(
                    _sortBySpeed ? Icons.speed : Icons.speed_outlined,
                    size: 18,
                    color: _sortBySpeed ? AppColors.tint : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '速度',
                    style: TextStyle(
                      fontSize: 12,
                      color: _sortBySpeed ? AppColors.tint : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          InkWell(
            onTap: _enterBulkForCurrentFilter,
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Row(
                children: [
                  Icon(
                    Icons.checklist,
                    size: 18,
                    color: AppColors.tint,
                  ),
                  SizedBox(width: 2),
                  Text(
                    '批量',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.tint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBulkBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _bulkBusy ? null : () => _bulkSetEnabled(false),
                icon: const Icon(Icons.block, size: 18),
                label: const Text('禁用'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _bulkBusy ? null : () => _bulkSetEnabled(true),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('启用'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _bulkBusy ? null : _bulkDelete,
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
