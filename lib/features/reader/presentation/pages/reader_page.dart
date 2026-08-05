import 'dart:async';
import 'dart:convert';
import 'package:screen_brightness/screen_brightness.dart';
import '../../../../core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/services/bookmark_service.dart';
import '../../data/services/note_service.dart';
import '../../domain/entities/bookmark.dart';
import '../../domain/entities/reading_note.dart';
import '../../data/services/tts_service.dart';
import '../../../settings/domain/usecases/reading_stats_service.dart';
import '../providers/reader_provider.dart';
import '../widgets/page_view_widget.dart';
import '../widgets/bookmark_sheet.dart';
import '../widgets/chapter_search_sheet.dart';
import '../widgets/note_sheet.dart';
import '../../../../features/search/domain/entities/search_result.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
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
  final NoteService _noteService = NoteService();

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
  /// 进入阅读页时的应用亮度，退出时恢复（阅读页存活期间亮度才生效）
  double? _entryBrightness;

  @override
  void initState() {
    super.initState();
    _pageOpenTime = DateTime.now();
    // 记录进入时的亮度，页面退出时恢复
    ScreenBrightness().application.then((value) {
      if (mounted) _entryBrightness = value;
    }).catchError((_) {
      // 平台不支持时跳过
    });
    ref.read(readerProvider.notifier).resetForBook(widget.bookId, detailUrl: widget.detailUrl);
    Future.microtask(() async {
      // 读取保存的进度，续读到正确章节
      final repo = ref.read(readerRepositoryProvider);
      final progress = await repo.loadProgress(widget.bookId);
      final startChapter = progress?.chapterIndex ?? 0;
      final sourceId = (widget.sourceId != null && widget.sourceId!.isNotEmpty)
          ? widget.sourceId
          : 'default';
      ref.read(readerProvider.notifier).loadChapter(
        bookId: widget.bookId,
        chapterIndex: startChapter,
        sourceId: sourceId!,
        detailUrl: widget.detailUrl,
      );
    });
  }

  @override
  void dispose() {
    ref.read(readerProvider.notifier).syncShelfNow();
    // 释放 TTS：停止朗读、置空回调，防止离页后回调 UI
    unawaited(_tts.dispose());
    // 恢复进入阅读页前的亮度（仅阅读页存活期间亮度生效）
    final entry = _entryBrightness;
    if (entry != null) {
      unawaited(ScreenBrightness()
          .setApplicationScreenBrightness(entry)
          .catchError((_) {}));
    } else {
      unawaited(ScreenBrightness()
          .resetApplicationScreenBrightness()
          .catchError((_) {}));
    }
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

    // 过滤已禁用的书源：搜索时的替代源列表是静态快照，
    // 源可能在搜索后被禁用，换源时不应再展示/使用
    final repo = ref.read(bookSourceRepositoryProvider);
    final enabledAlternatives = <SourceOption>[];
    for (final alt in _alternatives) {
      final source = await repo.getById(alt.sourceId);
      if (source != null && source.enabled) {
        enabledAlternatives.add(alt);
      }
    }
    if (!mounted) return;

    final selected = await showModalBottomSheet<SourceOption>(
      context: context,
      builder: (_) => SourceSwitcherSheet(
        currentSourceId: chapter.sourceId ?? widget.sourceId ?? '',
        currentSourceName: widget.sourceId != null ? '当前书源' : '当前书源',
        alternatives: enabledAlternatives,
      ),
    );
    if (selected != null && mounted && selected.bookId.isNotEmpty) {
      // 切换到新书源（保留替代书源列表，参数做 URL 编码）
      final alts = jsonEncode(_alternatives.map((a) => {
        'bookId': a.bookId,
        'sourceId': a.sourceId,
        'sourceName': a.sourceName,
        'detailUrl': a.detailUrl,
      }).toList());
      context.pushReplacement(
        '/reader/${Uri.encodeComponent(selected.bookId)}'
        '?sourceId=${Uri.encodeComponent(selected.sourceId)}'
        '&detailUrl=${Uri.encodeComponent(selected.detailUrl ?? '')}'
        '&alternatives=${Uri.encodeComponent(alts)}',
      );
    }
  }

  Future<void> _addNote() async {
    final state = ref.read(readerProvider);
    final chapter = state.currentChapter;
    if (chapter == null) return;

    final controller = TextEditingController();
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('添加笔记'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            decoration: const InputDecoration(hintText: '写下你的想法...'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
          ],
        ),
      );
      if (saved == true && controller.text.trim().isNotEmpty && mounted) {
        await _noteService.add(ReadingNote(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          bookId: widget.bookId,
          chapterIndex: chapter.index,
          text: controller.text.trim(),
          createdAt: DateTime.now(),
        ));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('笔记已保存')),
        );
      }
    } finally {
      // 对话框关闭后释放控制器，避免泄漏
      controller.dispose();
    }
  }

  void _openNotes() {
    showModalBottomSheet(
      context: context,
      builder: (_) => NoteSheet(bookId: widget.bookId),
    );
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
      if (mounted) setState(() => _isTtsPlaying = false);
    } else {
      _tts.onComplete = () {
        if (mounted) setState(() => _isTtsPlaying = false);
      };
      // 先置位播放状态再 await：防快速连点重复启动朗读；
      // 播放中再次点击会走上面的停止分支，不会吞掉停止操作
      setState(() => _isTtsPlaying = true);
      await _tts.speak(state.currentChapter!.content);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);

    // 切章（loadChapter 成功/失败）时先停止朗读，避免旧章节内容继续播放
    ref.listen<ReaderState>(readerProvider, (previous, next) {
      if (_isTtsPlaying &&
          previous?.currentChapter?.id != next.currentChapter?.id) {
        _tts.stop();
        if (mounted) setState(() => _isTtsPlaying = false);
      }
    });

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
                      // TTS 听书按钮
                      IconButton(
                        icon: Icon(
                          _isTtsPlaying ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                          color: _isTtsPlaying ? AppColors.tint : state.theme.textColor,
                        ),
                        onPressed: _toggleTts,
                        tooltip: _isTtsPlaying ? '停止朗读' : '朗读本章',
                      ),
                      IconButton(
                        icon: Icon(Icons.settings, color: state.theme.textColor),
                        onPressed: () => ref.read(readerProvider.notifier).toggleSettings(),
                      ),
                      // 更多菜单
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_horiz, color: state.theme.textColor),
                        color: Colors.white,
                        onSelected: (value) {
                          switch (value) {
                            case 'prev':
                              ref.read(readerProvider.notifier).prevChapter();
                              break;
                            case 'next':
                              ref.read(readerProvider.notifier).nextChapter();
                              break;
                            case 'catalog':
                              _openCatalog();
                              break;
                            case 'search':
                              _openChapterSearch();
                              break;
                            case 'bookmark_add':
                              _toggleBookmark();
                              break;
                            case 'bookmarks':
                              _openBookmarks();
                              break;
                            case 'note_add':
                              _addNote();
                              break;
                            case 'notes':
                              _openNotes();
                              break;
                            case 'source':
                              _openSourceSwitcher();
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'prev',
                            enabled: ref.read(readerProvider.notifier).hasPrevChapter,
                            child: const _MenuRow(icon: Icons.skip_previous, label: '上一章'),
                          ),
                          PopupMenuItem(
                            value: 'next',
                            enabled: ref.read(readerProvider.notifier).hasNextChapter,
                            child: const _MenuRow(icon: Icons.skip_next, label: '下一章'),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'catalog',
                            child: _MenuRow(icon: Icons.list, label: '章节目录'),
                          ),
                          const PopupMenuItem(
                            value: 'search',
                            child: _MenuRow(icon: Icons.search, label: '搜索本章'),
                          ),
                          if (_alternatives.isNotEmpty)
                            const PopupMenuItem(
                              value: 'source',
                              child: _MenuRow(icon: Icons.swap_horiz, label: '切换书源'),
                            ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'bookmark_add',
                            child: _MenuRow(icon: Icons.bookmark_add_outlined, label: '添加书签'),
                          ),
                          const PopupMenuItem(
                            value: 'bookmarks',
                            child: _MenuRow(icon: Icons.bookmarks_outlined, label: '书签列表'),
                          ),
                          const PopupMenuItem(
                            value: 'note_add',
                            child: _MenuRow(icon: Icons.sticky_note_2_outlined, label: '添加笔记'),
                          ),
                          const PopupMenuItem(
                            value: 'notes',
                            child: _MenuRow(icon: Icons.notes_outlined, label: '笔记列表'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Expanded(child: ReaderPageView()),
              ],
            ),
            if (state.showSettings)
              const Positioned(
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

/// 弹出菜单行
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.textSecondary),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontSize: 14)),
      ],
    );
  }
}
