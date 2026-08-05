import 'dart:async';
import 'package:dio/dio.dart';
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

  /// 当前生效的搜索关键词（防抖后），驱动结果 provider
  String _keyword = '';
  Timer? _debounce;

  /// 当前批次搜索的取消令牌：换词/清空/销毁时取消，中断旧批次网络请求
  CancelToken? _searchCancel;

  @override
  void initState() {
    super.initState();
    _historyFuture = _historyService.getRecent();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCancel?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// 触发新搜索：取消旧批次、换上新令牌后驱动 provider。
  /// 关键词未变时直接复用现有批次（与旧行为一致，避免同词重启）。
  void _startSearch(String trimmed) {
    if (trimmed == _keyword) return;
    _searchCancel?.cancel();
    final token = CancelToken();
    _searchCancel = token;
    ref.read(searchCancelTokenProvider.notifier).set(token);
    setState(() {
      _keyword = trimmed;
      _historyFuture = _historyService.getRecent();
    });
    _historyService.add(trimmed);
  }

  /// 输入防抖：停止输入 350ms 后自动搜索，避免每键触发全源网络请求
  void _onKeywordChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      // 清空关键词：取消在途请求并回到空状态
      _searchCancel?.cancel();
      _searchCancel = null;
      ref.read(searchCancelTokenProvider.notifier).set(null);
      setState(() => _keyword = '');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _startSearch(trimmed);
    });
  }

  void _search(String keyword) {
    _debounce?.cancel();
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    // 同步输入框文本，避免输入框与结果关键词不一致
    _searchController.text = trimmed;
    _startSearch(trimmed);
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
              onChanged: _onKeywordChanged,
              onSubmitted: _search,
            ),
          ),
          Expanded(
            child: _keyword.isEmpty
                ? _buildEmptyState()
                : ref.watch(searchResultsProvider(_keyword)).when(
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
                        avatar: const Icon(Icons.history, size: 16, color: AppColors.tint),
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
