import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/services/search_history_service.dart';
import '../providers/search_provider.dart';
import '../widgets/search_result_item.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchController = TextEditingController();
  final _historyService = SearchHistoryService();
  late Future<List<String>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = _historyService.getRecent();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _search(String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    _historyService.add(trimmed);
    setState(() {
      _historyFuture = _historyService.getRecent();
    });
    // ignore: unused_result
    ref.refresh(searchResultsProvider(trimmed));
  }

  void _clearHistory() async {
    await _historyService.clear();
    if (mounted) {
      setState(() {
        _historyFuture = _historyService.getRecent();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: false,
              decoration: InputDecoration(
                hintText: '搜索书籍',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onSubmitted: _search,
            ),
          ),
          Expanded(
            child: _searchController.text.isEmpty
                ? _buildEmptyState()
                : ref.watch(searchResultsProvider(_searchController.text)).when(
                    data: (results) => ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) => SearchResultItem(result: results[index]),
                    ),
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('搜索失败: $e')),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return FutureBuilder<List<String>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        final history = snapshot.data ?? [];
        if (history.isEmpty) {
          return const Center(
            child: Text('输入关键词搜索书籍', style: TextStyle(color: AppColors.textSecondary)),
          );
        }
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('搜索历史', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  TextButton.icon(
                    onPressed: _clearHistory,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: const Text('清空', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: history
                  .map((keyword) => ActionChip(
                        avatar: Icon(Icons.history, size: 16, color: AppColors.tint),
                        label: Text(keyword, style: const TextStyle(fontSize: 13)),
                        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
                        side: const BorderSide(color: AppColors.separator),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        onPressed: () {
                          _searchController.text = keyword;
                          _search(keyword);
                        },
                      ))
                  .toList(),
            ),
          ],
        );
      },
    );
  }
}
