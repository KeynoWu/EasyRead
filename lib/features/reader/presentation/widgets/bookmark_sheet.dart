import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/services/bookmark_service.dart';
import '../../domain/entities/bookmark.dart';

/// 书签列表面板
class BookmarkSheet extends StatefulWidget {
  final String bookId;

  const BookmarkSheet({super.key, required this.bookId});

  @override
  State<BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<BookmarkSheet> {
  final _service = BookmarkService();
  late Future<List<Bookmark>> _bookmarksFuture;

  @override
  void initState() {
    super.initState();
    _bookmarksFuture = _service.getBookmarks(widget.bookId);
  }

  void _reload() {
    setState(() {
      _bookmarksFuture = _service.getBookmarks(widget.bookId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 400,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('书签', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Bookmark>>(
              future: _bookmarksFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final bookmarks = snapshot.data ?? [];
                if (bookmarks.isEmpty) {
                  return const Center(child: Text('暂无书签'));
                }
                return ListView.builder(
                  itemCount: bookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = bookmarks[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.bookmark, color: AppColors.tint),
                      title: Text('第 ${bookmark.chapterIndex + 1} 章 · 第 ${bookmark.pageIndex + 1} 页'),
                      subtitle: Text(_formatTime(bookmark.createdAt)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () async {
                          await _service.remove(bookmark.id);
                          _reload();
                        },
                      ),
                      onTap: () => Navigator.pop(context, bookmark),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
