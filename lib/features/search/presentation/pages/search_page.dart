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
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '搜索书籍',
            border: InputBorder.none,
          ),
          onSubmitted: (value) => ref.refresh(searchResultsProvider(value)),
        ),
      ),
      body: _searchController.text.isEmpty
          ? const Center(child: Text('输入关键词搜索书籍', style: TextStyle(color: AppColors.textSecondary)))
          : ref.watch(searchResultsProvider(_searchController.text)).when(
              data: (results) => ListView.builder(
                itemCount: results.length,
                itemBuilder: (context, index) => SearchResultItem(result: results[index]),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('搜索失败: $e')),
            ),
    );
  }
}
