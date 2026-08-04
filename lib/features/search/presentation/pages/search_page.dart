import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/search_provider.dart';
import '../widgets/search_result_item.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
              onSubmitted: (value) => ref.refresh(searchResultsProvider(value)),
            ),
          ),
          Expanded(
            child: _searchController.text.isEmpty
                ? const Center(child: Text('输入关键词搜索书籍', style: TextStyle(color: AppColors.textSecondary)))
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
}
