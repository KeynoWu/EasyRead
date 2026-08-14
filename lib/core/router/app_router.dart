import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/bookshelf/presentation/pages/bookshelf_page.dart';
import '../../features/book_source/domain/entities/book_source.dart';
import '../../features/book_source/presentation/pages/book_source_import_page.dart';
import '../../features/book_source/presentation/pages/book_source_list_page.dart';
import '../../features/book_source/presentation/pages/book_source_edit_page.dart';
import '../../features/book_source/presentation/pages/book_source_login_page.dart';
import '../../features/book_source/presentation/pages/book_source_test_page.dart';
import '../../features/book_source/presentation/pages/rule_tester_page.dart';
import '../../features/book_source/presentation/pages/subscription_page.dart';
import '../../features/book_source/presentation/pages/book_source_debug_page.dart';
import '../../features/book_source/presentation/providers/book_source_provider.dart';
import '../../features/discover/presentation/pages/discover_page.dart';
import '../../features/discover/presentation/pages/explore_books_page.dart';
import '../../features/reader/presentation/pages/reader_page.dart';
import '../../features/reader/presentation/pages/book_detail_page.dart';
import '../../features/reader/presentation/pages/book_marks_notes_page.dart';
import '../../features/search/presentation/pages/search_page.dart';
import '../../features/search/domain/entities/search_result.dart';
import '../../features/settings/presentation/pages/settings_page.dart';
import '../../features/settings/presentation/pages/webdav_config_page.dart';
import '../../features/settings/presentation/pages/purification_rules_page.dart';
import '../../features/settings/presentation/pages/reading_stats_page.dart';
import '../../features/shell/presentation/pages/main_shell.dart';
import '../../features/subscription_source/presentation/pages/rss_entries_page.dart';
import '../../features/subscription_source/presentation/pages/rss_entry_detail_page.dart';
import '../../features/subscription_source/presentation/pages/subscription_sources_page.dart';

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/bookshelf',
    routes: [
      // 底部导航：书架 / 搜索 / 发现 / 书源 / 设置（各 tab 可深链）。
      // 各 tab 的模态子页面（编辑/登录/测试/设置等）挂在对应 branch 内，
      // push 时保留底部导航栏，与旧 Navigator.push 行为一致。
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
            GoRoute(
              path: '/discover/explore',
              name: 'exploreBooks',
              builder: (context, state) =>
                  ExploreBooksPage(category: state.extra as DiscoverCategory),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/book-source',
              name: 'bookSource',
              builder: (context, state) => const BookSourceListPage(),
            ),
            GoRoute(
              path: '/book-source/edit',
              name: 'bookSourceEdit',
              builder: (context, state) {
                final repo = ProviderScope.containerOf(context)
                    .read(bookSourceRepositoryProvider);
                return BookSourceEditPage(
                  repository: repo,
                  source: state.extra as BookSource?,
                );
              },
            ),
            GoRoute(
              path: '/book-source/login',
              name: 'bookSourceLogin',
              builder: (context, state) =>
                  BookSourceLoginPage(source: state.extra as BookSource),
            ),
            GoRoute(
              path: '/book-source/rule-tester',
              name: 'ruleTester',
              builder: (context, state) =>
                  RuleTesterPage(source: state.extra as BookSource?),
            ),
            GoRoute(
              path: '/book-source/test',
              name: 'bookSourceTest',
              builder: (context, state) => const BookSourceTestPage(),
            ),
            GoRoute(
              path: '/book-source/subscription',
              name: 'bookSourceSubscription',
              builder: (context, state) {
                final repo = ProviderScope.containerOf(context)
                    .read(bookSourceRepositoryProvider);
                return SubscriptionPage(repository: repo);
              },
            ),
            GoRoute(
              path: '/book-source/debug',
              name: 'bookSourceDebug',
              builder: (context, state) =>
                  BookSourceDebugPage(source: state.extra as BookSource),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              name: 'settings',
              builder: (context, state) => const SettingsPage(),
            ),
            GoRoute(
              path: '/settings/webdav',
              name: 'webdavConfig',
              builder: (context, state) => const WebDavConfigPage(),
            ),
            GoRoute(
              path: '/settings/purification',
              name: 'purificationRules',
              builder: (context, state) => const PurificationRulesPage(),
            ),
            GoRoute(
              path: '/settings/stats',
              name: 'readingStats',
              builder: (context, state) => const ReadingStatsPage(),
            ),
            GoRoute(
              path: '/settings/bookmarks-notes',
              name: 'bookMarksNotes',
              builder: (context, state) => const BookMarksNotesPage(),
            ),
          ]),
        ],
      ),
      GoRoute(
        path: '/book-source/import',
        name: 'bookSourceImport',
        builder: (context, state) => const BookSourceImportPage(),
      ),
      // 书籍详情：搜索 tab 与阅读器换源两处入口统一走 root 级路由
      // （全屏覆盖，返回语义与原 Navigator.push 一致）。
      GoRoute(
        path: '/book-detail',
        name: 'bookDetail',
        builder: (context, state) =>
            BookDetailPage(result: state.extra as SearchResult),
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
