import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/services/search_history_service.dart';
import '../../domain/usecases/search_books.dart';
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

  /// 当前生效的搜索关键词，驱动结果 provider（仅手动搜索/回车时更新）
  String _keyword = '';

  /// 当前批次搜索的取消令牌：换词/清空/销毁时取消，中断旧批次网络请求
  CancelToken? _searchCancel;

  @override
  void initState() {
    super.initState();
    _historyFuture = _historyService.getRecent();
  }

  @override
  void dispose() {
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

  /// 输入变化：仅处理清空（取消在途请求回到空状态）；
  /// 搜索由搜索按钮/键盘回车显式触发
  void _onKeywordChanged(String value) {
    if (value.trim().isNotEmpty) return;
    _searchCancel?.cancel();
    _searchCancel = null;
    ref.read(searchCancelTokenProvider.notifier).set(null);
    setState(() => _keyword = '');
  }

  /// 执行搜索：同步输入框文本、收起键盘后触发
  void _search(String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    // 同步输入框文本，避免输入框与结果关键词不一致
    _searchController.text = trimmed;
    FocusScope.of(context).unfocus(); // 收起键盘，避免遮挡结果
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
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索书籍',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () => _search(_searchController.text),
                  tooltip: '搜索',
                ),
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
                    data: (progress) => _buildResults(progress),
                    loading: () => _buildSearchingState(),
                    error: (_, _) => _buildErrorState(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(SearchProgress progress) {
    final results = progress.results;
    return Column(
      children: [
        Expanded(
          child: results.isEmpty
              ? (progress.finished
                  ? _buildNoResultState(progress)
                  : const Center(child: CircularProgressIndicator()))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, index) =>
                      SearchResultItem(result: results[index]),
                ),
        ),
        // 搜索进度条：流式显示已完成的源数
        if (!progress.finished)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress.total == 0
                        ? 0
                        : progress.completed / progress.total,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${progress.completed}/${progress.total} 源'
                  '${progress.failed > 0 ? ' · ${progress.failed} 失败' : ''}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSearchingState() {
    // loading 态：显示可搜索的书源数量，避免"正在转圈但不知道在等什么"
    final count = ref.watch(enabledSearchableCountProvider).value;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            count == null
                ? '正在搜索…'
                : (count == 0
                    ? '没有可用的书源，请到书源管理中开启'
                    : '正在从 $count 个书源搜索…'),
            style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildNoResultState(SearchProgress progress) {
    // 有源请求失败时区分"全部失败/部分失败"与"真无结果"：
    // 失败源数在最终态也展示，并给出重试入口
    final failed = progress.failed;
    final allFailed = failed > 0 && failed >= progress.completed;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 56, color: AppColors.textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            allFailed ? '搜索失败' : '未找到相关书籍',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              failed > 0
                  ? '${progress.failed} 个书源请求失败，其余源未返回结果'
                  : '可尝试更换关键词；若所有书源均被禁用，请到书源管理中开启',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
          if (failed > 0) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _startSearch(_keyword),
              child: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 56, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          const Text('搜索失败，请检查网络后重试', style: TextStyle(fontSize: 15, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => _startSearch(_keyword),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  /// 删除单条历史
  Future<void> _removeHistory(String keyword) async {
    await _historyService.remove(keyword);
    if (mounted) {
      setState(() {
        _historyFuture = _historyService.getRecent();
      });
    }
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
                  .map((keyword) => InputChip(
                        avatar: const Icon(Icons.history, size: 16, color: AppColors.tint),
                        label: Text(keyword, style: const TextStyle(fontSize: 13)),
                        backgroundColor: isDark ? AppColors.darkSurface : Colors.white,
                        side: const BorderSide(color: AppColors.separator),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        deleteIcon: Icon(Icons.close, size: 14, color: AppColors.textSecondary.withValues(alpha: 0.6)),
                        onDeleted: () => _removeHistory(keyword),
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
