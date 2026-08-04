import 'package:go_router/go_router.dart';
import '../../features/shell/presentation/pages/main_shell.dart';
import '../../features/book_source/presentation/pages/book_source_import_page.dart';
import '../../features/reader/presentation/pages/reader_page.dart';

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const MainShell(),
      ),
      GoRoute(
        path: '/book-source/import',
        name: 'bookSourceImport',
        builder: (context, state) => const BookSourceImportPage(),
      ),
      GoRoute(
        path: '/reader/:bookId',
        name: 'reader',
        builder: (context, state) {
          final bookId = state.pathParameters['bookId'] ?? '';
          final sourceId = state.uri.queryParameters['sourceId'];
          final detailUrl = state.uri.queryParameters['detailUrl'];
          return ReaderPage(
            bookId: bookId,
            sourceId: sourceId,
            detailUrl: detailUrl,
          );
        },
      ),
    ],
  );
}
