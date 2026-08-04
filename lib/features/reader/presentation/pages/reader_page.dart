import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/services/bookmark_service.dart';
import '../../domain/entities/bookmark.dart';
import '../../data/services/tts_service.dart';
import '../../../settings/domain/usecases/reading_stats_service.dart';
import '../providers/reader_provider.dart';
import '../widgets/page_view_widget.dart';
import '../widgets/bookmark_sheet.dart';
import '../widgets/chapter_search_sheet.dart';
import '../../../../features/search/domain/entities/search_result.dart';
import '../widgets/chapter_catalog_sheet.dart';
import '../widgets/reader_settings_panel.dart';
import '../widgets/source_switcher_sheet.dart';

class ReaderPage extends ConsumerStatefulWidget {
  final String bookId;
  final String? sourceId;
  final String? detailUrl;
  final String? alternativesJson;

  const ReaderPage({
    super.key,
    required this.bookId,
    this.sourceId,
    this.detailUrl,
    this.alternativesJson,
  });

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  final TtsService _tts = TtsService();
  final ReadingStatsService _statsService = ReadingStatsService();
  final BookmarkService _bookmarkService = BookmarkService();

  /// 解析替代书源
  List<SourceOption> get _alternatives {
    final json = widget.alternativesJson;
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json) as List;
      return list.map((e) {
        final map = e as Map<String, dynamic>;
        return SourceOption(
          bookId: map['bookId']?.toString() ?? '',
          sourceId: map['sourceId']?.toString() ?? '',
          sourceName: map['sourceName']?.toString() ?? '未知书源',
          detailUrl: map['detailUrl']?.toString(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
  bool _isTtsPlaying = false;
  DateTime? _pageOpenTime;

  @override
  void initState() {
    super.initState();
    _pageOpenTime = DateTime.now();
    Future.microtask(() async {
      // 读取保存的进度，续读到正确章节
      final repo = ref.read(readerRepositoryProvider);
      final progress = await repo.loadProgress(widget.bookId);
      final startChapter = progress?.chapterIndex ?? 0;
      ref.read(readerProvider.notifier).loadChapter(
        bookId: widget.bookId,
        chapterIndex: startChapter,
        sourceId: widget.sourceId ?? 'default',
        detailUrl: widget.detailUrl,
      );
    });
  }

  @override
  void dispose() {
    _tts.stop();
    // 记录本次阅读时长
    final openTime = _pageOpenTime;
    if (openTime != null) {
      final elapsed = DateTime.now().difference(openTime).inSeconds;
      if (elapsed > 5) {
        _statsService.recordSession(elapsed);
      }
    }
    super.dispose();
  }

  Future<void> _openBookmarks() async {
    final state = ref.read(readerProvider);
    if (state.currentChapter == null) return;

    // 打开书签列表；若选择书签则跳转
    final selected = await showModalBottomSheet<dynamic>(
      context: context,
      builder: (_) => BookmarkSheet(bookId: widget.bookId),
    );
    if (selected != null && mounted) {
      final bookmark = selected;
      await ref.read(readerProvider.notifier).jumpToChapter(bookmark.chapterIndex);
      if (mounted) {
        ref.read(readerProvider.notifier).jumpToPage(bookmark.pageIndex);
      }
    }
  }

  Future<void> _toggleBookmark() async {
    final state = ref.read(readerProvider);
    if (state.currentChapter == null) return;

    final chapter = state.currentChapter!;
    final exists = await _bookmarkService.exists(widget.bookId, chapter.index, state.currentPage);
    if (exists) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该位置已有书签')),
      );
      return;
    }

    await _bookmarkService.add(Bookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      bookId: widget.bookId,
      chapterIndex: chapter.index,
      pageIndex: state.currentPage,
      createdAt: DateTime.now(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('书签已添加')),
    );
  }

  Future<void> _openSourceSwitcher() async {
    final state = ref.read(readerProvider);
    final chapter = state.currentChapter;
    if (chapter == null) return;

    final selected = await showModalBottomSheet<SourceOption>(
      context: context,
      builder: (_) => SourceSwitcherSheet(
        currentSourceId: chapter.sourceId ?? widget.sourceId ?? '',
        currentSourceName: widget.sourceId != null ? '当前书源' : '当前书源',
        alternatives: _alternatives,
      ),
    );
    if (selected != null && mounted && selected.bookId.isNotEmpty) {
      // 切换到新书源
      context.pushReplacement(
        '/reader/${selected.bookId}?sourceId=${selected.sourceId}&detailUrl=${selected.detailUrl ?? ''}',
      );
    }
  }

  void _openChapterSearch() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ChapterSearchSheet(),
    );
  }

  void _openCatalog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ChapterCatalogSheet(),
    );
  }

  Future<void> _toggleTts() async {
    final state = ref.read(readerProvider);
    if (state.currentChapter == null) return;

    if (_isTtsPlaying) {
      await _tts.stop();
      setState(() => _isTtsPlaying = false);
    } else {
      await _tts.speak(state.currentChapter!.content);
      setState(() => _isTtsPlaying = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);

    return Scaffold(
      backgroundColor: state.theme.backgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: state.theme.backgroundColor,
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back, color: state.theme.textColor),
                        onPressed: () => context.pop(),
                      ),
                      const Spacer(),
                      if (state.currentChapter != null)
                        Text(
                          state.currentChapter!.title,
                          style: TextStyle(color: state.theme.textColor, fontSize: 14),
                        ),
                      const Spacer(),
                      // 上一章
                      IconButton(
                        icon: Icon(Icons.skip_previous, color: state.theme.textColor),
                        onPressed: ref.read(readerProvider.notifier).hasPrevChapter
                            ? () => ref.read(readerProvider.notifier).prevChapter()
                            : null,
                        tooltip: '上一章',
                      ),
                      // 下一章
                      IconButton(
                        icon: Icon(Icons.skip_next, color: state.theme.textColor),
                        onPressed: ref.read(readerProvider.notifier).hasNextChapter
                            ? () => ref.read(readerProvider.notifier).nextChapter()
                            : null,
                        tooltip: '下一章',
                      ),
                      // 章节搜索按钮
                      IconButton(
                        icon: Icon(Icons.search, color: state.theme.textColor),
                        onPressed: _openChapterSearch,
                        tooltip: '搜索本章',
                      ),
                      // 换源按钮
                      if (_alternatives.isNotEmpty)
                        IconButton(
                          icon: Icon(Icons.swap_horiz, color: state.theme.textColor),
                          onPressed: _openSourceSwitcher,
                          tooltip: '切换书源',
                        ),
                      // 书签按钮
                      IconButton(
                        icon: Icon(Icons.bookmark_add_outlined, color: state.theme.textColor),
                        onPressed: _toggleBookmark,
                        tooltip: '添加书签',
                      ),
                      IconButton(
                        icon: Icon(Icons.bookmarks_outlined, color: state.theme.textColor),
                        onPressed: _openBookmarks,
                        tooltip: '书签列表',
                      ),
                      // 目录按钮
                      IconButton(
                        icon: Icon(Icons.list, color: state.theme.textColor),
                        onPressed: _openCatalog,
                        tooltip: '章节目录',
                      ),
                      // TTS 听书按钮
                      IconButton(
                        icon: Icon(
                          _isTtsPlaying ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                          color: _isTtsPlaying ? Colors.green : state.theme.textColor,
                        ),
                        onPressed: _toggleTts,
                        tooltip: _isTtsPlaying ? '停止朗读' : '朗读本章',
                      ),
                      IconButton(
                        icon: Icon(Icons.settings, color: state.theme.textColor),
                        onPressed: () => ref.read(readerProvider.notifier).toggleSettings(),
                      ),
                    ],
                  ),
                ),
                Expanded(child: ReaderPageView()),
              ],
            ),
            if (state.showSettings)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ReaderSettingsPanel(),
              ),
          ],
        ),
      ),
    );
  }
}
