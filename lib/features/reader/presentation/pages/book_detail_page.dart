import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../features/bookshelf/domain/entities/book.dart';
import '../../../../features/bookshelf/presentation/providers/bookshelf_provider.dart';
import '../../../../features/search/domain/entities/search_result.dart';
import '../../domain/entities/book_detail.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/entities/reading_progress.dart';
import '../providers/reader_provider.dart';

/// 书籍详情页：展示简介/作者/封面/目录，再决定开始阅读或指定章节阅读。
class BookDetailPage extends ConsumerStatefulWidget {
  final SearchResult result;

  const BookDetailPage({super.key, required this.result});

  @override
  ConsumerState<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends ConsumerState<BookDetailPage> {
  BookDetail? _detail;
  ChapterCatalog? _catalog;
  bool _loading = true;
  bool _caching = false;
  int _cachedCount = 0;
  String? _error;

  SearchResult get result => widget.result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(readerRepositoryProvider);
      final detail = await repo.getBookDetail(
        bookId: result.bookId,
        sourceId: result.sourceId,
        detailUrl: result.detailUrl ?? '',
        variables: result.variables,
      );
      final catalog = await repo.getCatalog(
        bookId: result.bookId,
        sourceId: result.sourceId,
        detailUrl: result.detailUrl ?? '',
        variables: result.variables,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _catalog = catalog;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '详情加载失败，请检查网络或书源规则';
      });
    }
  }

  Future<void> _openAt(int chapterIndex) async {
    final detail = _detail;
    final catalog = _catalog;
    final now = DateTime.now();
    final bookshelfRepo = ref.read(bookshelfRepositoryProvider);
    final detailService = ref.read(bookDetailServiceProvider);
    final readerRepo = ref.read(readerRepositoryProvider);

    await bookshelfRepo.save(Book(
      id: result.bookId,
      name: detail?.name ?? result.name,
      author: detail?.author ?? result.author,
      coverUrl: detail?.coverUrl ?? result.coverUrl,
      sourceId: result.sourceId,
      lastChapter: catalog == null || catalog.chapters.isEmpty
          ? null
          : catalog.chapters.last.title,
      lastReadAt: now,
    ));
    await detailService.save(
      result.bookId,
      detailUrl: result.detailUrl,
      alternativesJson: jsonEncode([
        for (final alt in result.alternatives)
          {
            'bookId': alt.bookId,
            'sourceId': alt.sourceId,
            'sourceName': alt.sourceName,
            'detailUrl': alt.detailUrl,
          },
      ]),
      variablesJson: jsonEncode(result.variables),
    );
    if (chapterIndex > 0) {
      await readerRepo.saveProgress(ReadingProgress(
        bookId: result.bookId,
        chapterIndex: chapterIndex,
        pageIndex: 0,
        updatedAt: now,
      ));
    }
    ref.invalidate(bookshelfListProvider);
    if (!mounted) return;
    context.push(
      '/reader/${Uri.encodeComponent(result.bookId)}'
      '?sourceId=${Uri.encodeComponent(result.sourceId)}'
      '&detailUrl=${Uri.encodeComponent(result.detailUrl ?? '')}'
      '&alternatives=${Uri.encodeComponent(jsonEncode([
        for (final alt in result.alternatives)
          {
            'bookId': alt.bookId,
            'sourceId': alt.sourceId,
            'sourceName': alt.sourceName,
            'detailUrl': alt.detailUrl,
          },
      ]))}'
      '&variables=${Uri.encodeComponent(jsonEncode(result.variables))}',
    );
  }

  Future<void> _openSourcePicker() async {
    final current = result;
    final selected = await showModalBottomSheet<SourceOption>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check, color: AppColors.tint),
              title: Text(current.sourceName),
              subtitle: const Text('当前书源'),
              onTap: () => Navigator.pop(
                context,
                SourceOption(
                  bookId: current.bookId,
                  sourceId: current.sourceId,
                  sourceName: current.sourceName,
                  detailUrl: current.detailUrl,
                ),
              ),
            ),
            for (final alt in current.alternatives)
              ListTile(
                leading: const Icon(Icons.swap_horiz, color: AppColors.tint),
                title: Text(alt.sourceName),
                onTap: () => Navigator.pop(context, alt),
              ),
          ],
        ),
      ),
    );
    if (selected == null ||
        selected.sourceId == current.sourceId ||
        !mounted) {
      return;
    }
    final next = SearchResult(
      bookId: selected.bookId,
      name: current.name,
      author: current.author,
      coverUrl: current.coverUrl,
      detailUrl: selected.detailUrl,
      sourceId: selected.sourceId,
      sourceName: selected.sourceName,
      intro: current.intro,
      kind: current.kind,
      lastChapter: current.lastChapter,
      wordCount: current.wordCount,
      alternatives: current.alternatives,
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(result: next)),
    );
  }

  Future<void> _cacheAll() async {
    final catalog = _catalog;
    if (_caching || catalog == null || catalog.chapters.isEmpty) return;
    setState(() {
      _caching = true;
      _cachedCount = 0;
    });
    final repo = ref.read(readerRepositoryProvider);
    for (final chapter in catalog.chapters) {
      try {
        await repo.getChapter(
          bookId: result.bookId,
          chapterIndex: chapter.index,
          sourceId: result.sourceId,
          detailUrl: result.detailUrl ?? '',
          variables: result.variables,
        );
      } catch (_) {
        // 单章失败不中断整本缓存
      }
      if (!mounted) return;
      setState(() => _cachedCount++);
    }
    if (!mounted) return;
    setState(() => _caching = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final detail = _detail;
    final name = detail?.name ?? result.name;
    final author = detail?.author ?? result.author;
    final cover = detail?.coverUrl ?? result.coverUrl;

    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍详情'),
        actions: [
          if (result.alternatives.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: '换源',
              onPressed: _openSourcePicker,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: AppColors.textSecondary),
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: AppColors.textSecondary)),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 88,
                            height: 124,
                            color: AppColors.separator.withValues(alpha: 0.3),
                            child: cover != null
                                ? Image.network(
                                    cover,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const Icon(Icons.auto_stories, size: 40),
                                  )
                                : const Icon(Icons.auto_stories, size: 40),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (author != null)
                                Text(author, style: const TextStyle(color: AppColors.textSecondary)),
                              const SizedBox(height: 6),
                              Text(
                                result.sourceName,
                                style: const TextStyle(fontSize: 12, color: AppColors.tint),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () => _openAt(0),
                                      icon: const Icon(Icons.menu_book_outlined, size: 18),
                                      label: const Text('开始阅读'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed:
                                          _caching || _catalog == null || _catalog!.chapters.isEmpty
                                              ? null
                                              : _cacheAll,
                                      icon: _caching
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.download_outlined, size: 18),
                                      label: Text(
                                        _caching
                                            ? '$_cachedCount/${_catalog?.chapters.length ?? 0}'
                                            : '缓存全书',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (result.kind != null ||
                        result.lastChapter != null ||
                        result.wordCount != null ||
                        detail?.kind != null ||
                        detail?.lastChapter != null ||
                        detail?.wordCount != null) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (result.kind != null || detail?.kind != null)
                            _InfoChip(label: '分类', value: detail?.kind ?? result.kind!),
                          if (result.wordCount != null || detail?.wordCount != null)
                            _InfoChip(label: '字数', value: detail?.wordCount ?? result.wordCount!),
                          if (result.lastChapter != null || detail?.lastChapter != null)
                            _InfoChip(label: '最新', value: detail?.lastChapter ?? result.lastChapter!),
                        ],
                      ),
                    ],
                    if (result.intro != null || detail?.intro != null) ...[
                      const SizedBox(height: 20),
                      const Text('简介', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text(
                        detail?.intro ?? result.intro!,
                        style: const TextStyle(height: 1.5, color: AppColors.textSecondary),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Text(
                      '目录（${_catalog?.chapters.length ?? 0}）',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (_catalog == null || _catalog!.chapters.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: Text('暂无目录', style: TextStyle(color: AppColors.textSecondary))),
                      )
                    else
                      ..._catalog!.chapters.map(
                        (chapter) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => _openAt(chapter.index),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;

  const _InfoChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.tintSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('$label: $value', style: const TextStyle(fontSize: 12, color: AppColors.tint)),
    );
  }
}
