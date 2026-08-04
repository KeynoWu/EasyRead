import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/reader_provider.dart';

/// 章节内搜索面板
class ChapterSearchSheet extends ConsumerStatefulWidget {
  const ChapterSearchSheet({super.key});

  @override
  ConsumerState<ChapterSearchSheet> createState() => _ChapterSearchSheetState();
}

class _ChapterSearchSheetState extends ConsumerState<ChapterSearchSheet> {
  final _controller = TextEditingController();
  List<int> _matches = [];
  int _currentMatchIndex = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String keyword) {
    final notifier = ref.read(readerProvider.notifier);
    final matches = notifier.searchInChapter(keyword);
    setState(() {
      _matches = matches;
      _currentMatchIndex = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) {
      notifier.jumpToPage(matches.first);
    }
  }

  void _gotoMatch(int index) {
    if (_matches.isEmpty) return;
    final safeIndex = (_currentMatchIndex + index) % _matches.length;
    setState(() => _currentMatchIndex = safeIndex);
    ref.read(readerProvider.notifier).jumpToPage(_matches[safeIndex]);
  }

  @override
  Widget build(BuildContext context) {
    final totalMatches = _matches.length;
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: '搜索本章内容',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      isDense: true,
                    ),
                    onSubmitted: _search,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: totalMatches == 0 ? null : () => _gotoMatch(-1),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: totalMatches == 0 ? null : () => _gotoMatch(1),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              totalMatches == 0
                  ? (_controller.text.isEmpty ? '输入关键词搜索' : '未找到匹配内容')
                  : '共 $_currentMatchIndex/${totalMatches - 1} 处 · 第 ${_currentMatchIndex + 1}/$totalMatches 处',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
