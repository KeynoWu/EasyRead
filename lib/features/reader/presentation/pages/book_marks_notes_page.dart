import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/services/bookmark_service.dart';
import '../../data/services/note_service.dart';
import '../../domain/entities/bookmark.dart';
import '../../domain/entities/reading_note.dart';

/// 跨书统一查看/管理全部书签与笔记。
class BookMarksNotesPage extends StatelessWidget {
  const BookMarksNotesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书签与笔记'),
          bottom: const TabBar(tabs: [
            Tab(text: '书签'),
            Tab(text: '笔记'),
          ]),
        ),
        body: const TabBarView(children: [
          _AllBookmarksTab(),
          _AllNotesTab(),
        ]),
      ),
    );
  }
}

class _AllBookmarksTab extends StatefulWidget {
  const _AllBookmarksTab();

  @override
  State<_AllBookmarksTab> createState() => _AllBookmarksTabState();
}

class _AllBookmarksTabState extends State<_AllBookmarksTab> {
  final _service = BookmarkService();
  late Future<List<Bookmark>> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.getAll();
  }

  void _reload() {
    setState(() => _future = _service.getAll());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Bookmark>>(
      future: _future,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <Bookmark>[];
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) return const Center(child: Text('暂无书签'));
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              leading: const Icon(Icons.bookmark, color: AppColors.tint),
              title: Text('第 ${item.chapterIndex + 1} 章 · 第 ${item.pageIndex + 1} 页'),
              subtitle: Text(item.bookId),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () async {
                  await _service.removeById(item.id);
                  _reload();
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _AllNotesTab extends StatefulWidget {
  const _AllNotesTab();

  @override
  State<_AllNotesTab> createState() => _AllNotesTabState();
}

class _AllNotesTabState extends State<_AllNotesTab> {
  final _service = NoteService();
  late Future<List<ReadingNote>> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.getAll();
  }

  void _reload() {
    setState(() => _future = _service.getAll());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ReadingNote>>(
      future: _future,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <ReadingNote>[];
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) return const Center(child: Text('暂无笔记'));
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return Card(
              child: ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined, color: AppColors.tint),
                title: Text(item.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('第 ${item.chapterIndex + 1} 章 · ${item.bookId}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () async {
                    await _service.removeById(item.id);
                    _reload();
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}
