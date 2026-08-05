import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../domain/entities/book_source.dart';
import '../providers/book_source_provider.dart';
import '../widgets/book_source_card.dart';
import 'book_source_edit_page.dart';
import 'subscription_page.dart';

class BookSourceListPage extends ConsumerStatefulWidget {
  const BookSourceListPage({super.key});

  @override
  ConsumerState<BookSourceListPage> createState() => _BookSourceListPageState();
}

class _BookSourceListPageState extends ConsumerState<BookSourceListPage> {
  final Set<String> _pendingToggles = {};

  Future<void> _openEditor({String? sourceId}) async {
    final repo = ref.read(bookSourceRepositoryProvider);
    final source = sourceId != null ? await repo.getById(sourceId) : null;
    if (!mounted) return;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceEditPage(repository: repo, source: source),
      ),
    );
    if (changed == true) {
      ref.invalidate(bookSourceListProvider);
    }
  }

  Future<void> _toggleSource(BookSource source) async {
    if (_pendingToggles.contains(source.id)) return;
    _pendingToggles.add(source.id);
    try {
      final repo = ref.read(bookSourceRepositoryProvider);
      await repo.save(source.copyWith(enabled: !source.enabled));
      ref.invalidate(bookSourceListProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书源状态更新失败')),
        );
      }
    } finally {
      _pendingToggles.remove(source.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(bookSourceListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.rss_feed),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SubscriptionPage(repository: ref.read(bookSourceRepositoryProvider))),
            ),
            tooltip: '书源订阅',
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _openEditor(),
            tooltip: '新建书源',
          ),
        ],
      ),
      body: sourcesAsync.when(
        data: (sources) => ListView.builder(
          itemCount: sources.length,
          itemBuilder: (context, index) {
            final source = sources[index];
            return BookSourceCard(
              source: source,
              onTap: () => _openEditor(sourceId: source.id),
              onToggle: () => _toggleSource(source),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.pushNamed('bookSourceImport'),
        child: const Icon(Icons.add),
      ),
    );
  }
}
