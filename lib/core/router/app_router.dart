import 'package:go_router/go_router.dart';
import '../../features/bookshelf/presentation/pages/bookshelf_page.dart';
import '../../features/book_source/presentation/pages/book_source_list_page.dart';
import '../../features/book_source/presentation/pages/book_source_import_page.dart';
import '../../features/search/presentation/pages/search_page.dart';
import '../../features/reader/presentation/pages/reader_page.dart';

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'bookshelf',
        builder: (context, state) => const BookshelfPage(),
      ),
      GoRoute(
        path: '/search',
        name: 'search',
        builder: (context, state) => const SearchPage(),
      ),
      GoRoute(
        path: '/book-sources',
        name: 'bookSources',
        builder: (context, state) => const BookSourceListPage(),
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
          return ReaderPage(bookId: bookId);
        },
      ),
    ],
  );
}
