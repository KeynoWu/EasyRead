import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/services/note_service.dart';
import '../../domain/entities/reading_note.dart';

/// 笔记列表面板
class NoteSheet extends StatefulWidget {
  final String bookId;

  const NoteSheet({super.key, required this.bookId});

  @override
  State<NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<NoteSheet> {
  final _service = NoteService();
  late Future<List<ReadingNote>> _notesFuture;

  @override
  void initState() {
    super.initState();
    _notesFuture = _service.getNotes(widget.bookId);
  }

  void _reload() {
    setState(() {
      _notesFuture = _service.getNotes(widget.bookId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 400,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('笔记', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<ReadingNote>>(
              future: _notesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final notes = snapshot.data ?? [];
                if (notes.isEmpty) {
                  return const Center(child: Text('暂无笔记'));
                }
                return ListView.builder(
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return Card(
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.sticky_note_2_outlined, color: AppColors.tint),
                        title: Text(
                          note.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '第 ${note.chapterIndex + 1} 章 · ${_formatTime(note.createdAt)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () async {
                            await _service.remove(note.id);
                            _reload();
                          },
                        ),
                      ),
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
