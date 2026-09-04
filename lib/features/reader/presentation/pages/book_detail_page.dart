import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/app_router.dart' show ReaderRouteArgs;
import '../../../../core/theme/app_colors.dart';
import '../../../../features/bookshelf/domain/entities/book.dart';
import '../../../../features/bookshelf/presentation/providers/bookshelf_provider.dart';
import '../../../../features/search/domain/entities/search_result.dart';
import '../../data/services/book_cache_service.dart';
import '../../domain/entities/book_detail.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/entities/reading_progress.dart';
import '../providers/reader_provider.dart';
import '../widgets/cover_image.dart';

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
  ReadingProgress? _progress;
  bool _loading = true;
  bool _caching = false;
  /// 目录默认折叠：进入详情页先看正文（简介/开始阅读），需要目录时再展开
  bool _catalogExpanded = false;
  // 缓存进度走局部 ValueNotifier：每缓存一章只刷新按钮文本，
  // 避免 setState 高频重建包含整个目录 ListView 的页面。
  final ValueNotifier<int> _cachedCount = ValueNotifier<int>(0);
  CancelToken? _cacheCancelToken;
  String? _error;

  SearchResult get result => widget.result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cacheCancelToken?.cancel();
    _cachedCount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(readerRepositoryProvider);
      // 详情/目录/进度并行拉取，缩短白屏等待
      final results = await Future.wait<Object?>([
        repo.getBookDetail(
          bookId: result.bookId,
          sourceId: result.sourceId,
          detailUrl: result.detailUrl ?? '',
          variables: result.variables,
        ),
        repo.getCatalog(
          bookId: result.bookId,
          sourceId: result.sourceId,
          detailUrl: result.detailUrl ?? '',
          variables: result.variables,
        ),
        repo.loadProgress(result.bookId),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as BookDetail;
        _catalog = results[1] as ChapterCatalog;
        _progress = results[2] as ReadingProgress?;
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

  Future<void> _openAt(int chapterIndex, {bool overwriteProgress = false}) async {
    final detail = _detail;
    final catalog = _catalog;
    final now = DateTime.now();
    final bookshelfRepo = ref.read(bookshelfRepositoryProvider);
    final detailService = ref.read(bookDetailServiceProvider);
    final readerRepo = ref.read(readerRepositoryProvider);
    // 目录点击（含第 1 章）覆盖进度写入；「开始阅读」为续读入口，
    // 不写进度（否则点一下预览就把深进度重置回第 1 章）
    if (overwriteProgress) {
      await readerRepo.saveProgress(
        ReadingProgress(
          bookId: result.bookId,
          chapterIndex: chapterIndex,
          pageIndex: 0,
          updatedAt: now,
          sourceId: result.sourceId,
        ),
      );
    }
    await bookshelfRepo.save(
      Book(
        id: result.bookId,
        name: detail?.name ?? result.name,
        author: detail?.author ?? result.author,
        coverUrl: detail?.coverUrl ?? result.coverUrl,
        sourceId: result.sourceId,
        lastChapter: catalog == null || catalog.chapters.isEmpty
            ? null
            : catalog.chapters.last.title,
        lastReadAt: now,
      ),
    );
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
    ref.invalidate(bookshelfListProvider);
    if (!mounted) return;
    context.push(
      '/reader/${Uri.encodeComponent(result.bookId)}',
      extra: ReaderRouteArgs(
        bookId: result.bookId,
        sourceId: result.sourceId,
        detailUrl: result.detailUrl,
        alternativesJson: jsonEncode([
          for (final alt in result.alternatives) {'bookId': alt.bookId, 'sourceId': alt.sourceId, 'sourceName': alt.sourceName, 'detailUrl': alt.detailUrl},
        ]),
        variablesJson: jsonEncode(result.variables),
      ),
    );
  }

  Future<void> _openSourcePicker() async {
    final current = result;
    final selected = await showModalBottomSheet<SourceOption>(
      context: context,
      // 书源可达上百个：限制高度并用 ListView 滚动，避免 Column 溢出
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: ListView(
            shrinkWrap: true,
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
      ),
    );
    if (selected == null || selected.sourceId == current.sourceId || !mounted) {
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
      variables: current.variables,
    );
    context.pushReplacement('/book-detail', extra: next);
  }

  Future<void> _cacheAll() async {
    final catalog = _catalog;
    if (_caching || catalog == null || catalog.chapters.isEmpty) {
      return;
    }
    setState(() {
      _caching = true;
    });
    _cachedCount.value = 0;
    final cancelToken = CancelToken();
    _cacheCancelToken = cancelToken;
    try {
      final service = BookCacheService(
        repository: ref.read(readerRepositoryProvider),
      );
      final cacheResult = await service.cacheBook(
        bookId: result.bookId,
        sourceId: result.sourceId,
        detailUrl: result.detailUrl ?? '',
        chapters: catalog.chapters,
        variables: result.variables,
        cancelToken: cancelToken,
        onProgress: (done, total, title) {
          if (!mounted) return;
          _cachedCount.value = done;
        },
      );
      if (!mounted) return;
      final message = cacheResult.cancelled
          ? '已取消缓存（已缓存 ${cacheResult.cached + cacheResult.hit} 章）'
          : cacheResult.failed > 0
          ? '缓存完成：新增 ${cacheResult.cached} 章，命中 ${cacheResult.hit} 章，失败 ${cacheResult.failed} 章'
          : '缓存完成：新增 ${cacheResult.cached} 章，命中 ${cacheResult.hit} 章';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('缓存失败：$e')));
    } finally {
      if (mounted) {
        setState(() {
          _caching = false;
          _cacheCancelToken = null;
        });
      }
    }
  }

  /// 缓存进行中再次点击按钮：取消本次缓存
  void _cancelCache() {
    _cacheCancelToken?.cancel();
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
      // 本地优先：直接用搜索结果已有数据渲染（书名/作者/封面/简介），
      // 详情/目录网络数据到达后填充，不再整页白屏转圈
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 48,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
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
                            ? CoverImage(
                                url: cover,
                                sourceId: widget.result.sourceId,
                                width: 88,
                                height: 124,
                                fallbackIcon: const Icon(
                                  Icons.auto_stories,
                                  size: 40,
                                ),
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
                              color: isDark
                                  ? AppColors.darkTextPrimary
                                  : AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (author != null)
                            Text(
                              author,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          const SizedBox(height: 6),
                          Text(
                            result.sourceName,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.tint,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () => _openAt(0),
                                  icon: const Icon(
                                    Icons.menu_book_outlined,
                                    size: 18,
                                  ),
                                  // 有保存进度时实际行为是续读，文案随之变化
                                  label: Text(
                                    _progress == null
                                        ? '开始阅读'
                                        : _progressLabel(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _caching
                                      ? _cancelCache
                                      : _catalog == null ||
                                            _catalog!.chapters.isEmpty
                                      ? null
                                      : _cacheAll,
                                  icon: _caching
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.download_outlined,
                                          size: 18,
                                        ),
                                  label: ValueListenableBuilder<int>(
                                    valueListenable: _cachedCount,
                                    builder: (context, count, _) => Text(
                                      _caching
                                          ? '$count/${_catalog?.chapters.length ?? 0}'
                                          : '缓存全书',
                                    ),
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
                        _InfoChip(
                          label: '分类',
                          value: detail?.kind ?? result.kind!,
                        ),
                      if (result.wordCount != null || detail?.wordCount != null)
                        _InfoChip(
                          label: '字数',
                          value: detail?.wordCount ?? result.wordCount!,
                        ),
                      if (result.lastChapter != null ||
                          detail?.lastChapter != null)
                        _InfoChip(
                          label: '最新',
                          value: detail?.lastChapter ?? result.lastChapter!,
                        ),
                    ],
                  ),
                ],
                if (result.intro != null || detail?.intro != null) ...[
                  const SizedBox(height: 20),
                  const Text(
                    '简介',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    detail?.intro ?? result.intro!,
                    style: const TextStyle(
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                // 目录：默认折叠，点击标题行展开/收起（与正文分开，需要时才显示）
                InkWell(
                  onTap: (_catalog == null || _catalog!.chapters.isEmpty)
                      ? null
                      : () => setState(() => _catalogExpanded = !_catalogExpanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Text(
                          '目录（${_catalog?.chapters.length ?? 0}）',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        if (_catalog != null && _catalog!.chapters.isNotEmpty)
                          Icon(
                            _catalogExpanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_catalog == null)
                  // 目录未加载完成：细进度条 + 加载中文案（不再整页白屏）
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        if (_loading)
                          const LinearProgressIndicator(minHeight: 2),
                        const SizedBox(height: 12),
                        Text(
                          _loading ? '目录加载中…' : '暂无目录',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (_catalog!.chapters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '暂无目录',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  )
                else if (_catalogExpanded)
                  // 目录独立滚动区域 + 惰性构建：千章书籍不再一次性构建全部 ListTile
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.5,
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: _catalog!.chapters.length,
                      itemBuilder: (context, index) {
                        final chapter = _catalog!.chapters[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            chapter.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          // 目录跳转：任意章（含第 1 章）都覆盖进度，确保点第 1 章真的跳转
                          onTap: () => _openAt(chapter.index, overwriteProgress: true),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  /// 续读按钮文案：展示保存进度所在章节的百分比（目录未加载时仅显示"继续阅读"）
  String _progressLabel() {
    final catalog = _catalog;
    final progress = _progress;
    if (catalog == null || progress == null || catalog.chapters.isEmpty) {
      return '继续阅读';
    }
    final pct = ((progress.chapterIndex / catalog.chapters.length) * 100).round();
    return '继续阅读 ${pct.clamp(0, 100)}%';
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
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 12, color: AppColors.tint),
      ),
    );
  }
}
