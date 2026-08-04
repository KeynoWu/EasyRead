import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/source_subscription.dart';
import '../../domain/repositories/book_source_repository.dart';
import '../../domain/usecases/manage_subscription.dart';

/// 书源订阅管理页面
class SubscriptionPage extends StatefulWidget {
  final BookSourceRepository repository;

  const SubscriptionPage({super.key, required this.repository});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  late final ManageSubscription _manager;
  late Future<List<SourceSubscription>> _subsFuture;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _manager = ManageSubscription(bookSourceRepository: widget.repository);
    _subsFuture = _manager.getAll();
  }

  void _reload() {
    setState(() {
      _subsFuture = _manager.getAll();
    });
  }

  Future<void> _addSubscription() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加订阅'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '订阅名称')),
            const SizedBox(height: 12),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: '订阅地址'), keyboardType: TextInputType.url),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('添加')),
        ],
      ),
    );
    if (result == true && urlController.text.trim().isNotEmpty) {
      await _manager.add(
        nameController.text.trim().isEmpty ? '订阅${DateTime.now().millisecondsSinceEpoch % 1000}' : nameController.text.trim(),
        urlController.text.trim(),
      );
      _reload();
    }
  }

  Future<void> _updateAll() async {
    setState(() => _updating = true);
    final count = await _manager.updateAll();
    if (!mounted) return;
    setState(() => _updating = false);
    _reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('更新完成，共更新 $count 个书源')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源订阅'),
        actions: [
          IconButton(
            icon: _updating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            onPressed: _updating ? null : _updateAll,
            tooltip: '更新全部',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addSubscription,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<SourceSubscription>>(
        future: _subsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final subs = snapshot.data ?? [];
          if (subs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.rss_feed, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('暂无订阅', style: TextStyle(fontSize: 16)),
                  SizedBox(height: 8),
                  Text('添加订阅地址，自动更新书源', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }
          return ListView.builder(
            itemCount: subs.length,
            itemBuilder: (context, index) {
              final sub = subs[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.rss_feed, color: AppColors.tint),
                  title: Text(sub.name),
                  subtitle: Text(
                    sub.lastUpdateResult ?? (sub.lastUpdatedAt != null ? '更新于 ${_formatTime(sub.lastUpdatedAt!)}' : '尚未更新'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.sync, size: 20),
                        onPressed: () async {
                          final count = await _manager.updateSubscription(sub);
                          if (!mounted) return;
                          _reload();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('更新了 $count 个书源')),
                          );
                        },
                        tooltip: '更新此订阅',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () async {
                          await _manager.remove(sub.id);
                          _reload();
                        },
                        tooltip: '删除订阅',
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
