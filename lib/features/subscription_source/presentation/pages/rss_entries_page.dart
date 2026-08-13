import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/rss_entry.dart';
import '../providers/subscription_source_provider.dart';

/// 条目列表页：标题/时间/摘要（2 行省略），按发布时间倒序，
/// 下拉刷新重新拉取，点击进入 WebView 详情。
class RssEntriesPage extends ConsumerStatefulWidget {
  final String sourceId;

  const RssEntriesPage({super.key, required this.sourceId});

  @override
  ConsumerState<RssEntriesPage> createState() => _RssEntriesPageState();
}

class _RssEntriesPageState extends ConsumerState<RssEntriesPage> {
  List<RssEntry>? _entries;
  String? _error;
  String _sourceName = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(subscriptionSourceServiceProvider);
      final source = await service.getById(widget.sourceId);
      if (source == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _entries = const [];
            _error = '订阅源不存在或已删除';
          });
        }
        return;
      }
      final result =
          await ref.read(subscriptionRepositoryProvider).fetchEntries(source);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _sourceName = source.name;
        if (result.isSuccess) {
          _entries = [...result.entries]..sort(_byPubDateDesc);
        } else {
          _entries = const [];
          _error = result.error;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _entries = const [];
          _error = '加载失败';
        });
      }
    }
  }

  /// 发布时间倒序；无日期条目排最后。
  static int _byPubDateDesc(RssEntry a, RssEntry b) {
    final ta = a.pubDate?.millisecondsSinceEpoch;
    final tb = b.pubDate?.millisecondsSinceEpoch;
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return tb.compareTo(ta);
  }

  void _openDetail(RssEntry entry) {
    if (entry.link.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该条目没有可访问的链接')),
      );
      return;
    }
    context.push(
      '/subscriptions/entry'
      '?url=${Uri.encodeComponent(entry.link)}'
      '&title=${Uri.encodeComponent(entry.title)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _sourceName.isEmpty ? '条目列表' : _sourceName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && entries!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 48,
                          color: AppColors.textSecondary),
                      const SizedBox(height: 12),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textSecondary)),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: entries!.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final author =
                          entry.author == null ? '' : ' · ${entry.author}';
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: ListTile(
                          title: Text(
                            entry.title.isEmpty ? '（无标题）' : entry.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_formatTime(entry.pubDate)}$author',
                                style: const TextStyle(fontSize: 12),
                              ),
                              if (entry.description != null &&
                                  entry.description!.isNotEmpty)
                                Text(
                                  entry.description!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                            ],
                          ),
                          trailing:
                              const Icon(Icons.chevron_right, size: 18),
                          onTap: () => _openDetail(entry),
                        ),
                      );
                    },
                  ),
                ),
    );
  }

  static String _formatTime(DateTime? t) {
    if (t == null) return '时间未知';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
