import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/book_source_provider.dart';
import '../widgets/book_source_card.dart';

class BookSourceListPage extends ConsumerWidget {
  const BookSourceListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourcesAsync = ref.watch(bookSourceListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('书源管理')),
      body: sourcesAsync.when(
        data: (sources) => ListView.builder(
          itemCount: sources.length,
          itemBuilder: (context, index) => BookSourceCard(source: sources[index]),
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
