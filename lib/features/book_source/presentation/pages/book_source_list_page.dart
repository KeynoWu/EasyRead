import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/book_source_provider.dart';
import '../widgets/book_source_card.dart';
import 'book_source_edit_page.dart';
import 'subscription_page.dart';

class BookSourceListPage extends ConsumerWidget {
  const BookSourceListPage({super.key});

  Future<void> _openEditor(BuildContext context, WidgetRef ref, {String? sourceId}) async {
    final repo = ref.read(bookSourceRepositoryProvider);
    final source = sourceId != null ? await repo.getById(sourceId) : null;
    if (!context.mounted) return;
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            onPressed: () => _openEditor(context, ref),
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
              onTap: () => _openEditor(context, ref, sourceId: source.id),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.pushNamed(context, '/book-source/import'),
        child: const Icon(Icons.add),
      ),
    );
  }
}
