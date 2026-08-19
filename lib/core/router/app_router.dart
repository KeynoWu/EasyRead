import 'package:flutter/cupertino.dart' show CupertinoPage;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/bookshelf/presentation/pages/bookshelf_page.dart';
import '../../features/book_source/domain/entities/book_source.dart';
import '../../features/book_source/presentation/pages/book_source_import_page.dart';
import '../../features/book_source/presentation/pages/book_source_list_page.dart';
import '../../features/book_source/presentation/pages/book_source_edit_page.dart';
import '../../features/book_source/presentation/pages/book_source_login_page.dart';
import '../../features/book_source/presentation/pages/book_source_test_page.dart';
import '../../features/book_source/presentation/providers/book_source_provider.dart';
import '../../features/reader/presentation/pages/reader_page.dart';
import '../../features/reader/presentation/pages/book_detail_page.dart';
import '../../features/search/presentation/pages/search_page.dart';
import '../../features/search/domain/entities/search_result.dart';
import '../../features/settings/presentation/pages/settings_page.dart';
import '../../features/settings/presentation/pages/purification_rules_page.dart';
import '../../features/shell/presentation/pages/main_shell.dart';

/// iOS 原生转场页面包装：CupertinoPage 提供滑入转场 + 边缘右滑返回手势，
/// 让 iOS 上的导航手感接近原生（替代默认 Material 缩放转场）。
/// MaterialApp.router 已提供 MaterialLocalizations，CupertinoPage 可正常使用
/// Material 组件。
Page<T> _cupertino<T>(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  return CupertinoPage<T>(
    key: state.pageKey,
    child: child,
  );
}

/// 阅读器路由参数：经 go_router extra 传递对象，避免复杂 JSON 塞 URL query 后
/// 编解码脆弱/URL 超长。深链场景仍可从 URL query 兜底读取（见路由 builder）。
class ReaderRouteArgs {
  final String bookId;
  final String? sourceId;
  final String? detailUrl;
  final String? alternativesJson;
  final String? variablesJson;

  const ReaderRouteArgs({
    required this.bookId,
    this.sourceId,
    this.detailUrl,
    this.alternativesJson,
    this.variablesJson,
  });
}

/// 应用路由（Riverpod provider 持有，随 ProviderScope 生命周期管理；
/// builder 内经 ProviderScope.containerOf(context).read 读取各 feature provider）。
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/bookshelf',
    routes: [
      // 底部导航：书架 / 搜索 / 书源 / 设置（各 tab 可深链）。
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
              pageBuilder: (context, state) => _cupertino(context, state, const BookshelfPage()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/search',
              name: 'search',
              pageBuilder: (context, state) => _cupertino(context, state, const SearchPage()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/book-source',
              name: 'bookSource',
              pageBuilder: (context, state) => _cupertino(context, state, const BookSourceListPage()),
            ),
            GoRoute(
              path: '/book-source/edit',
              name: 'bookSourceEdit',
              pageBuilder: (context, state) {
                final repo = ProviderScope.containerOf(context)
                    .read(bookSourceRepositoryProvider);
                final extra = state.extra;
                return _cupertino(
                  context,
                  state,
                  BookSourceEditPage(
                    repository: repo,
                    source: extra is BookSource ? extra : null,
                  ),
                );
              },
            ),
            GoRoute(
              path: '/book-source/login',
              name: 'bookSourceLogin',
              pageBuilder: (context, state) {
                final extra = state.extra;
                return _cupertino(
                  context,
                  state,
                  extra is BookSource
                      ? BookSourceLoginPage(source: extra)
                      : const BookSourceListPage(),
                );
              },
            ),
            GoRoute(
              path: '/book-source/test',
              name: 'bookSourceTest',
              pageBuilder: (context, state) => _cupertino(context, state, const BookSourceTestPage()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              name: 'settings',
              pageBuilder: (context, state) => _cupertino(context, state, const SettingsPage()),
            ),
            GoRoute(
              path: '/settings/purification',
              name: 'purificationRules',
              pageBuilder: (context, state) => _cupertino(context, state, const PurificationRulesPage()),
            ),
          ]),
        ],
      ),
      GoRoute(
        path: '/book-source/import',
        name: 'bookSourceImport',
        pageBuilder: (context, state) => _cupertino(context, state, const BookSourceImportPage()),
      ),
      // 书籍详情：搜索 tab 与阅读器换源两处入口统一走 root 级路由
      // （全屏覆盖，返回语义与原 Navigator.push 一致）。
      GoRoute(
        path: '/book-detail',
        name: 'bookDetail',
        pageBuilder: (context, state) {
          final extra = state.extra;
          return _cupertino(
            context,
            state,
            extra is SearchResult
                ? BookDetailPage(result: extra)
                : const SearchPage(),
          );
        },
      ),
      GoRoute(
        path: '/reader/:bookId',
        name: 'reader',
        pageBuilder: (context, state) {
          // 优先用 extra 传对象（避免 JSON 塞 query）；深链 keep 起来自 query 的兜底。
          final extra = state.extra;
          if (extra is ReaderRouteArgs) {
            return _cupertino(
              context,
              state,
              ReaderPage(
                bookId: extra.bookId,
                sourceId: extra.sourceId,
                detailUrl: extra.detailUrl,
                alternativesJson: extra.alternativesJson,
                variablesJson: extra.variablesJson,
              ),
            );
          }
          final bookId = state.pathParameters['bookId'] ?? '';
          final sourceId = state.uri.queryParameters['sourceId'];
          final detailUrl = state.uri.queryParameters['detailUrl'];
          final alternativesJson = state.uri.queryParameters['alternatives'];
          final variablesJson = state.uri.queryParameters['variables'];
          return _cupertino(
            context,
            state,
            ReaderPage(
              bookId: bookId,
              sourceId: sourceId,
              detailUrl: detailUrl,
              alternativesJson: alternativesJson,
              variablesJson: variablesJson,
            ),
          );
        },
      ),
    ],
  );
});
