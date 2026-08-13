import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/subscription_source.dart';
import '../providers/subscription_source_provider.dart';

/// 订阅源管理页：源列表（名称/URL/最后更新时间）+
/// FAB 添加（名称+URL）+ 长按菜单/左滑删除 + 下拉刷新（重拉全部源）。
class SubscriptionSourcesPage extends ConsumerStatefulWidget {
  const SubscriptionSourcesPage({super.key});

  @override
  ConsumerState<SubscriptionSourcesPage> createState() =>
      _SubscriptionSourcesPageState();
}

class _SubscriptionSourcesPageState
    extends ConsumerState<SubscriptionSourcesPage> {
  bool _refreshing = false;

  /// FAB：弹出名称+URL 对话框并保存。
  Future<void> _addSource() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加订阅源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名称'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(labelText: 'RSS/Atom 地址'),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final name = nameController.text.trim();
    final url = urlController.text.trim();
    nameController.dispose();
    urlController.dispose();
    if (saved != true || !mounted) return;
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称和地址不能为空')),
      );
      return;
    }
    await ref.read(subscriptionSourceServiceProvider).save(SubscriptionSource(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: name,
          url: url,
        ));
    ref.invalidate(subscriptionSourceListProvider);
  }

  /// 删除（带确认），供长按菜单与左滑删除共用。
  Future<bool> _confirmAndDelete(SubscriptionSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定删除「${source.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(subscriptionSourceServiceProvider).remove(source.id);
      ref.invalidate(subscriptionSourceListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除')),
        );
      }
    }
    return confirmed == true;
  }

  /// 长按菜单：单源刷新 / 删除。
  Future<void> _showSourceMenu(SubscriptionSource source) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('刷新此源'),
              onTap: () => Navigator.pop(context, 'refresh'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.danger),
              title: const Text('删除'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'refresh':
        final result =
            await ref.read(subscriptionRepositoryProvider).fetchEntries(source);
        ref.invalidate(subscriptionSourceListProvider);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            result.isSuccess ? '已更新 ${result.entryCount} 条' : result.error!,
          ),
        ));
      case 'delete':
        await _confirmAndDelete(source);
    }
  }

  /// 下拉刷新：依次重拉全部订阅源并更新 lastUpdatedAt（单源失败不中断）。
  Future<void> _refreshAll() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    var ok = 0;
    var failed = 0;
    try {
      final repo = ref.read(subscriptionRepositoryProvider);
      final service = ref.read(subscriptionSourceServiceProvider);
      for (final source in await service.getAll()) {
        final result = await repo.fetchEntries(source);
        if (result.isSuccess) {
          ok++;
        } else {
          failed++;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            failed == 0
                ? '已更新 $ok 个订阅源'
                : '更新完成：成功 $ok，失败 $failed',
          ),
        ));
      }
    } finally {
      ref.invalidate(subscriptionSourceListProvider);
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(subscriptionSourceListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('订阅源')),
      floatingActionButton: FloatingActionButton(
        onPressed: _addSource,
        tooltip: '添加订阅源',
        child: const Icon(Icons.add),
      ),
      body: sources.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('加载失败')),
        data: (list) {
          if (list.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Text(
                      '还没有订阅源\n点击右下角 + 添加 RSS/Atom 地址',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refreshAll,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: list.length,
              itemBuilder: (context, index) {
                final source = list[index];
                return Dismissible(
                  key: ValueKey(source.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: AppColors.danger,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child:
                        const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) => _confirmAndDelete(source),
                  child: Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: const Icon(Icons.rss_feed, color: AppColors.tint),
                      title: Text(source.name, maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(source.url, maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          Text(
                            source.lastUpdatedAt == null
                                ? '从未更新'
                                : '更新于 ${_formatTime(source.lastUpdatedAt!)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => context
                          .push('/subscriptions/${source.id}/entries'),
                      onLongPress: () => _showSourceMenu(source),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
