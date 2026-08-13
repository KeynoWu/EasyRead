import 'package:go_router/go_router.dart';
import '../../features/bookshelf/presentation/pages/bookshelf_page.dart';
import '../../features/book_source/presentation/pages/book_source_import_page.dart';
import '../../features/book_source/presentation/pages/book_source_list_page.dart';
import '../../features/reader/presentation/pages/reader_page.dart';
import '../../features/search/presentation/pages/search_page.dart';
import '../../features/settings/presentation/pages/settings_page.dart';
import '../../features/discover/presentation/pages/discover_page.dart';
import '../../features/shell/presentation/pages/main_shell.dart';
import '../../features/subscription_source/presentation/pages/rss_entries_page.dart';
import '../../features/subscription_source/presentation/pages/rss_entry_detail_page.dart';
import '../../features/subscription_source/presentation/pages/subscription_sources_page.dart';

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/bookshelf',
    routes: [
      // 底部导航：书架 / 搜索 / 书源 / 设置（各 tab 可深链）
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/bookshelf',
              name: 'bookshelf',
              builder: (context, state) => const BookshelfPage(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/search',
              name: 'search',
              builder: (context, state) => const SearchPage(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/discover',
              name: 'discover',
              builder: (context, state) => const DiscoverPage(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/book-source',
              name: 'bookSource',
              builder: (context, state) => const BookSourceListPage(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              name: 'settings',
              builder: (context, state) => const SettingsPage(),
            ),
          ]),
        ],
      ),
      GoRoute(
        path: '/book-source/import',
        name: 'bookSourceImport',
        builder: (context, state) => const BookSourceImportPage(),
      ),
      // 订阅源（RSS/Atom）
      GoRoute(
        path: '/subscriptions',
        name: 'subscriptions',
        builder: (context, state) => const SubscriptionSourcesPage(),
      ),
      GoRoute(
        path: '/subscriptions/:id/entries',
        name: 'subscriptionEntries',
        builder: (context, state) => RssEntriesPage(
          sourceId: state.pathParameters['id'] ?? '',
        ),
      ),
      // 条目链接经 query 传递（链接含斜杠等字符，不适合作 path 段）
      GoRoute(
        path: '/subscriptions/entry',
        name: 'subscriptionEntryDetail',
        builder: (context, state) => RssEntryDetailPage(
          url: state.uri.queryParameters['url'] ?? '',
          title: state.uri.queryParameters['title'] ?? '',
        ),
      ),
      GoRoute(
        path: '/reader/:bookId',
        name: 'reader',
        builder: (context, state) {
          final bookId = state.pathParameters['bookId'] ?? '';
          final sourceId = state.uri.queryParameters['sourceId'];
          final detailUrl = state.uri.queryParameters['detailUrl'];
          final alternativesJson = state.uri.queryParameters['alternatives'];
          final variablesJson = state.uri.queryParameters['variables'];
          return ReaderPage(
            bookId: bookId,
            sourceId: sourceId,
            detailUrl: detailUrl,
            alternativesJson: alternativesJson,
            variablesJson: variablesJson,
          );
        },
      ),
    ],
  );
}
