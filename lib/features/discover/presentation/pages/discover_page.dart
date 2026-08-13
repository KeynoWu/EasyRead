import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../book_source/domain/entities/book_source.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
import 'explore_books_page.dart';

class DiscoverCategory {
  final BookSource source;
  final String title;
  final String url;

  const DiscoverCategory({
    required this.source,
    required this.title,
    required this.url,
  });
}

/// 发现/榜单入口：解析书源 exploreUrl 的分类配置并进入书籍列表。
class DiscoverPage extends ConsumerWidget {
  const DiscoverPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(bookSourceListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          // 订阅源（RSS/Atom）入口
          IconButton(
            tooltip: '订阅源',
            icon: const Icon(Icons.rss_feed),
            onPressed: () => context.push('/subscriptions'),
          ),
        ],
      ),
      body: sources.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('加载失败')),
        data: (list) {
          final categories = [
            for (final source in list.where((s) =>
                s.enabled &&
                s.enabledExplore &&
                (s.exploreUrl?.isNotEmpty ?? false)))
              ..._parseCategories(source),
          ];
          if (categories.isEmpty) {
            return const Center(
              child: Text(
                '没有可用的发现书源\n请在书源管理中开启 exploreUrl 书源',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final category = categories[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.explore_outlined, color: AppColors.tint),
                  title: Text(category.title),
                  subtitle: Text(category.source.name),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExploreBooksPage(category: category),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  static List<DiscoverCategory> _parseCategories(BookSource source) {
    final raw = source.exploreUrl!.trim();
    if (raw.startsWith('[')) {
      try {
        final list = jsonDecode(raw) as List;
        return [
          for (final item in list)
            if (item is Map && item['url'] != null)
              DiscoverCategory(
                source: source,
                title: item['title']?.toString() ?? source.name,
                url: item['url'].toString(),
              ),
        ];
      } catch (_) {
        return const [];
      }
    }
    if (raw.startsWith('{')) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        if (map['url'] != null) {
          return [
            DiscoverCategory(
              source: source,
              title: map['title']?.toString() ?? source.name,
              url: map['url'].toString(),
            ),
          ];
        }
      } catch (_) {
        return const [];
      }
    }
    return [DiscoverCategory(source: source, title: source.name, url: raw)];
  }
}
