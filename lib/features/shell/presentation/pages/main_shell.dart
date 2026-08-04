import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../bookshelf/presentation/pages/bookshelf_page.dart';
import '../../../search/presentation/pages/search_page.dart';
import '../../../book_source/presentation/pages/book_source_list_page.dart';

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
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: AppColors.separator.withValues(alpha: 0.3)),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          backgroundColor: AppColors.background,
          selectedItemColor: AppColors.tint,
          unselectedItemColor: AppColors.textSecondary,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.library_books), label: '书架'),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: '搜索'),
            BottomNavigationBarItem(icon: Icon(Icons.link), label: '书源'),
          ],
        ),
      ),
    );
  }
}
