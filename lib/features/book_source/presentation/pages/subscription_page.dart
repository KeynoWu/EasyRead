import 'package:dio/dio.dart';
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
  int _updateDone = 0;
  int _updateTotal = 0;
  CancelToken? _updateToken;

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
    if (result == true) {
      if (!mounted) return;
      try {
        final url = urlController.text.trim();
        if (url.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请输入订阅地址')),
          );
          return;
        }
        if (!_isValidHttpUrl(url)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('订阅地址需为有效的 http/https 地址')),
          );
          return;
        }
        await _manager.add(
          nameController.text.trim().isEmpty ? '订阅${DateTime.now().millisecondsSinceEpoch % 1000}' : nameController.text.trim(),
          url,
        );
        _reload();
      } finally {
        nameController.dispose();
        urlController.dispose();
      }
    } else {
      nameController.dispose();
      urlController.dispose();
    }
  }

  Future<void> _updateAll() async {
    final token = CancelToken();
    setState(() {
      _updating = true;
      _updateDone = 0;
      _updateTotal = 0;
      _updateToken = token;
    });
    final count = await _manager.updateAll(
      cancelToken: token,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _updateDone = done;
          _updateTotal = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _updating = false;
      _updateToken = null;
    });
    _reload();
    final cancelled = token.isCancelled;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(cancelled ? '已取消更新' : '更新完成，共更新 $count 个书源')),
    );
  }

  void _cancelUpdate() {
    _updateToken?.cancel();
  }

  /// 校验 http/https 且 host 非空
  static bool _isValidHttpUrl(String input) {
    final uri = Uri.tryParse(input);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _updating && _updateTotal > 0 ? '正在更新 $_updateDone/$_updateTotal' : '书源订阅',
        ),
        bottom: _updating
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
        actions: [
          IconButton(
            icon: _updating ? const Icon(Icons.close) : const Icon(Icons.sync),
            onPressed: _updating ? _cancelUpdate : _updateAll,
            tooltip: _updating ? '取消更新' : '更新全部',
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
                  Icon(Icons.rss_feed, size: 64, color: AppColors.textSecondary),
                  SizedBox(height: 16),
                  Text('暂无订阅', style: TextStyle(fontSize: 16)),
                  SizedBox(height: 8),
                  Text('添加订阅地址，自动更新书源', style: TextStyle(color: AppColors.textSecondary)),
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
                        onPressed: _updating
                            ? null
                            : () async {
                                final count = await _manager.updateSubscription(sub);
                                if (!context.mounted) return;
                                _reload();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('更新了 $count 个书源')),
                                );
                              },
                        tooltip: '更新此订阅',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: _updating
                            ? null
                            : () async {
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
