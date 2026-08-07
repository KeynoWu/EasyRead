import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../search/data/repositories/search_repository_impl.dart';
import '../../../search/domain/entities/search_result.dart';
import '../../../search/presentation/widgets/search_result_item.dart';
import '../../../search/presentation/providers/search_provider.dart';
import 'discover_page.dart';

/// 发现分类下的书籍列表，支持 {{page}} 分页加载。
class ExploreBooksPage extends ConsumerStatefulWidget {
  final DiscoverCategory category;

  const ExploreBooksPage({super.key, required this.category});

  @override
  ConsumerState<ExploreBooksPage> createState() => _ExploreBooksPageState();
}

class _ExploreBooksPageState extends ConsumerState<ExploreBooksPage> {
  final List<SearchResult> _results = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _page = 1;

  SearchRepositoryImpl get _repo => ref.read(searchRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final page = reset ? 1 : _page + 1;
      final list = await _repo.exploreWithSource(
        widget.category.source,
        widget.category.url,
        page: page,
        throwOnError: true,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _results
            ..clear()
            ..addAll(list);
        } else {
          _results.addAll(list);
        }
        _page = page;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset) _error = '发现加载失败，请检查网络或书源规则';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.category.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(reset: true),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: AppColors.textSecondary),
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: AppColors.textSecondary)),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => _load(reset: true),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(reset: true),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _results.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _results.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return SearchResultItem(result: _results[index]);
                    },
                  ),
                ),
      bottomNavigationBar: _results.isEmpty || _loadingMore
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: OutlinedButton(
                  onPressed: () => _load(),
                  child: const Text('加载更多'),
                ),
              ),
            ),
    );
  }
}
