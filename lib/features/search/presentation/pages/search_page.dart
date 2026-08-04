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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('搜索历史', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  TextButton(
                    onPressed: _clearHistory,
                    child: const Text('清空', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: history
                    .map((keyword) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.history, size: 18, color: AppColors.textSecondary),
                          title: Text(keyword, style: const TextStyle(fontSize: 14)),
                          trailing: const Icon(Icons.north_west, size: 14, color: AppColors.textSecondary),
                          onTap: () {
                            _searchController.text = keyword;
                            _search(keyword);
                          },
                        ))
                    .toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}
