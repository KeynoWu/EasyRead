import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../bookshelf/presentation/pages/bookshelf_page.dart';
import '../../../search/presentation/pages/search_page.dart';
import '../../../book_source/presentation/pages/book_source_list_page.dart';
import '../../../settings/presentation/pages/settings_page.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    BookshelfPage(),
    SearchPage(),
    BookSourceListPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : AppColors.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
              blurRadius: 16,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) => setState(() => _currentIndex = index),
            backgroundColor: Colors.transparent,
            items: [
              _navItem(Icons.library_books_outlined, Icons.library_books, '书架', 0),
              _navItem(Icons.search_outlined, Icons.search, '搜索', 1),
              _navItem(Icons.link_outlined, Icons.link, '书源', 2),
              _navItem(Icons.settings_outlined, Icons.settings, '设置', 3),
            ],
          ),
        ),
      ),
    );
  }

  BottomNavigationBarItem _navItem(IconData outline, IconData filled, String label, int index) {
    return BottomNavigationBarItem(
      icon: Icon(outline),
      activeIcon: Icon(filled),
      label: label,
    );
  }
}
