import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/pagination/page_layout.dart';
import '../../core/parser/node_tree.dart';

import '../../core/parser/html_parser.dart';
import '../../core/theme/reader_theme.dart';
import '../../data/repositories/reader_repository_impl.dart';
import '../../domain/entities/chapter.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/entities/reading_progress.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
import '../../../bookshelf/domain/entities/book.dart';
import '../../../bookshelf/domain/repositories/bookshelf_repository.dart';
import '../../../bookshelf/presentation/providers/bookshelf_provider.dart';
import '../../../settings/presentation/providers/purify_pipeline_provider.dart';

final readerRepositoryProvider = Provider<ReaderRepositoryImpl>((ref) {
  // 注入真实书源仓库：否则默认 _EmptySourceRepo 会让所有章节读取返回占位内容
  final sourceRepo = ref.watch(bookSourceRepositoryProvider);
  final repo = ReaderRepositoryImpl(sourceRepo: sourceRepo);
  // 净化规则异步加载完成后注入管线（默认空规则，不影响功能）
  ref.watch(purifyPipelineProvider).whenData(repo.setPipeline);
  return repo;
});

/// 阅读模式
enum ReadingMode { page, scroll }

/// 阅读器状态
class ReaderState {
  final Chapter? currentChapter;
  final List<PageContent> pages;
  final int currentPage;
  final ReadingProgress? progress;
  final ChapterCatalog? catalog;
  final LayoutConfig layoutConfig;
  final ReaderThemeConfig theme;
  final bool isLoading;
  final bool showSettings;
  final String? errorMessage;
  final ReadingMode readingMode;
  final Size viewportSize;

  const ReaderState({
    this.readingMode = ReadingMode.page,
    this.currentChapter,
    this.pages = const [],
    this.currentPage = 0,
    this.progress,
    this.catalog,
    this.layoutConfig = const LayoutConfig(),
    this.theme = ReaderThemes.defaultTheme,
    this.isLoading = false,
    this.showSettings = false,
    this.errorMessage,
    this.viewportSize = const Size(400, 600),
  });

  static const Object _unset = Object();

  ReaderState copyWith({
    Object? currentChapter = _unset,
    List<PageContent>? pages,
    int? currentPage,
    Object? progress = _unset,
    Object? catalog = _unset,
    LayoutConfig? layoutConfig,
    ReaderThemeConfig? theme,
    bool? isLoading,
    bool? showSettings,
    Object? errorMessage = _unset,
    ReadingMode? readingMode,
    Size? viewportSize,
  }) {
    return ReaderState(
      currentChapter: currentChapter == _unset
          ? this.currentChapter
          : currentChapter as Chapter?,
      pages: pages ?? this.pages,
      currentPage: currentPage ?? this.currentPage,
      progress: progress == _unset ? this.progress : progress as ReadingProgress?,
      catalog: catalog == _unset ? this.catalog : catalog as ChapterCatalog?,
      layoutConfig: layoutConfig ?? this.layoutConfig,
      theme: theme ?? this.theme,
      isLoading: isLoading ?? this.isLoading,
      showSettings: showSettings ?? this.showSettings,
      errorMessage: errorMessage == _unset
          ? this.errorMessage
          : errorMessage as String?,
      readingMode: readingMode ?? this.readingMode,
      viewportSize: viewportSize ?? this.viewportSize,
    );
  }
}

class ReaderNotifier extends Notifier<ReaderState> {
  late final ReaderRepositoryImpl _repository;
  late final BookshelfRepository _bookshelfRepo;
  final HtmlContentParser _parser = HtmlContentParser();
  String? widgetDetailUrl;
  String? _activeBookId;
  String? _lastBookId;
  int _lastChapterIndex = 0;
  String? _lastSourceId;
  String? _lastDetailUrl;

  /// 请求序号：防止快速切章时旧请求覆盖新章节
  int _loadSeq = 0;

  @override
  ReaderState build() {
    _repository = ref.watch(readerRepositoryProvider);
    _bookshelfRepo = ref.watch(bookshelfRepositoryProvider);
    return const ReaderState();
  }

  /// 打开新书时清空上一本书残留的内容、目录和请求状态。
  void resetForBook(String bookId, {String? detailUrl}) {
    _loadSeq++;
    _activeBookId = bookId;
    widgetDetailUrl = detailUrl;
    _lastBookId = bookId;
    _lastChapterIndex = 0;
    _lastSourceId = null;
    _lastDetailUrl = detailUrl;
    state = state.copyWith(
      currentChapter: null,
      pages: const [],
      currentPage: 0,
      progress: null,
      catalog: null,
      isLoading: false,
      errorMessage: null,
    );
  }

  /// 加载章节
  Future<void> loadChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
  }) async {
    final seq = ++_loadSeq;
    final isNewBook = _activeBookId != bookId;
    _activeBookId = bookId;
    widgetDetailUrl = isNewBook ? detailUrl : (detailUrl ?? widgetDetailUrl);
    _lastBookId = bookId;
    _lastChapterIndex = chapterIndex;
    _lastSourceId = sourceId;
    _lastDetailUrl = widgetDetailUrl;
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final chapter = await _repository.getChapter(
        bookId: bookId,
        chapterIndex: chapterIndex,
        sourceId: sourceId,
        detailUrl: detailUrl,
      );
      if (seq != _loadSeq) return; // 已被更新的请求取代

      final nodes = _parser.parse(chapter.content);
      final pages = _paginate(nodes);

      final progress = await _repository.loadProgress(bookId);
      if (seq != _loadSeq) return;

      state = state.copyWith(
        currentChapter: chapter,
        pages: pages,
        currentPage: progress?.pageIndex ?? 0,
        progress: progress,
        isLoading: false,
        errorMessage: null,
      );

      // 异步加载目录
      _loadCatalog(
        bookId: bookId,
        sourceId: sourceId,
        detailUrl: detailUrl,
        seq: seq,
      );

      // 预加载后续 2 章（后台执行，不阻塞后续章节切换）
      // ignore: discarded_futures
      _repository.preloadChapters(
        bookId: bookId,
        startIndex: chapterIndex + 1,
        count: 2,
        sourceId: sourceId,
        detailUrl: detailUrl,
      );
      if (progress != null) {
        unawaited(_syncBookToShelf(progress));
      }
    } catch (e) {
      if (seq == _loadSeq) {
        state = state.copyWith(
          currentChapter: null,
          pages: const [],
          currentPage: 0,
          progress: null,
          catalog: null,
          isLoading: false,
          errorMessage: e is ChapterLoadException ? e.message : '章节加载失败，请重试',
        );
      }
    }
  }

  /// 使用当前视口与排版配置分页
  List<PageContent> _paginate(List<TextNode> nodes) {
    final vp = state.viewportSize;
    final layout = PageLayout(
      viewWidth: vp.width,
      viewHeight: vp.height,
      config: state.layoutConfig,
    );
    return layout.paginate(nodes);
  }

  /// 视口尺寸变化时更新分页（旋转 / 窗口缩放）
  void setViewport(double width, double height) {
    if (state.viewportSize.width == width && state.viewportSize.height == height) return;
    state = state.copyWith(viewportSize: Size(width, height));
    if (state.currentChapter != null) {
      final nodes = _parser.parse(state.currentChapter!.content);
      final pages = _paginate(nodes);
      final clampedPage = state.currentPage.clamp(0, pages.isEmpty ? 0 : pages.length - 1);
      state = state.copyWith(pages: pages, currentPage: clampedPage);
    }
  }

  /// 翻到下一页
  void nextPage() {
    if (state.currentPage < state.pages.length - 1) {
      state = state.copyWith(currentPage: state.currentPage + 1);
      _saveProgress();
    }
  }

  /// 翻到上一页
  void prevPage() {
    if (state.currentPage > 0) {
      state = state.copyWith(currentPage: state.currentPage - 1);
      _saveProgress();
    }
  }

  /// 跳转到指定页
  void jumpToPage(int page) {
    if (page >= 0 && page < state.pages.length) {
      state = state.copyWith(currentPage: page);
      _saveProgress();
    }
  }

  /// 滚动模式位置上报（offset 为 0~1 归一化位置）
  void updateScrollOffset(double offset) {
    if (state.currentChapter == null || state.readingMode != ReadingMode.scroll) return;
    final current = state.progress;
    state = state.copyWith(
      progress: current == null
          ? ReadingProgress(
              bookId: state.currentChapter!.bookId,
              chapterIndex: state.currentChapter!.index,
              scrollOffset: offset,
              updatedAt: DateTime.now(),
            )
          : current.copyWith(scrollOffset: offset, updatedAt: DateTime.now()),
    );
    _saveProgress();
  }

  /// 切换设置面板
  void toggleSettings() {
    state = state.copyWith(showSettings: !state.showSettings);
  }

  /// 更新排版配置
  void updateLayout(LayoutConfig config) {
    state = state.copyWith(layoutConfig: config, currentPage: 0);
    if (state.currentChapter != null) {
      final nodes = _parser.parse(state.currentChapter!.content);
      state = state.copyWith(pages: _paginate(nodes));
    }
  }

  /// 切换主题
  void switchTheme(ReaderThemeConfig theme) {
    state = state.copyWith(theme: theme);
  }

  /// 切换阅读模式（各模式使用自己的进度维度）
  void switchMode(ReadingMode mode) {
    if (mode == ReadingMode.page) {
      state = state.copyWith(
        readingMode: mode,
        currentPage: state.progress?.pageIndex ?? 0,
      );
    } else {
      state = state.copyWith(readingMode: mode, currentPage: 0);
    }
  }

  /// 在章节内搜索关键词，返回命中页码列表
  List<int> searchInChapter(String keyword) {
    if (keyword.trim().isEmpty || state.pages.isEmpty) return [];
    final results = <int>[];
    for (int i = 0; i < state.pages.length; i++) {
      final pageText = state.pages[i].nodes
          .where((n) => n.type == NodeType.paragraph || n.type == NodeType.text || n.type == NodeType.heading)
          .map((n) => n.text)
          .join();
      if (pageText.contains(keyword)) {
        results.add(i);
      }
    }
    return results;
  }

  /// 跳转到第一个命中关键词的页面
  bool jumpToMatch(String keyword) {
    final matches = searchInChapter(keyword);
    if (matches.isEmpty) return false;
    jumpToPage(matches.first);
    return true;
  }

  /// 加载章节目录
  Future<void> _loadCatalog({
    required String bookId,
    required String sourceId,
    String? detailUrl,
    required int seq,
  }) async {
    if (detailUrl == null || detailUrl.isEmpty) return;
    try {
      final catalog = await _repository.getCatalog(
        bookId: bookId,
        sourceId: sourceId,
        detailUrl: detailUrl,
      );
      if (_activeBookId != bookId || seq != _loadSeq) return;
      if (catalog.chapters.isNotEmpty) {
        state = state.copyWith(catalog: catalog);
        final progress = state.progress;
        if (progress != null) {
          unawaited(_syncBookToShelf(progress));
        }
      }
    } catch (_) {
      // 目录加载失败不影响正文阅读
    }
  }

  /// 跳转到指定章节
  Future<void> jumpToChapter(int chapterIndex) async {
    final chapter = state.currentChapter;
    if (chapter == null) return;
    await loadChapter(
      bookId: chapter.bookId,
      chapterIndex: chapterIndex,
      sourceId: chapter.sourceId ?? 'default',
      detailUrl: widgetDetailUrl,
    );
  }

  /// 下一章
  Future<void> nextChapter() async {
    final chapter = state.currentChapter;
    if (chapter == null) return;
    final catalog = state.catalog;
    if (catalog != null && chapter.index >= catalog.chapters.length - 1) return;
    await jumpToChapter(chapter.index + 1);
  }

  /// 上一章
  Future<void> prevChapter() async {
    final chapter = state.currentChapter;
    if (chapter == null || chapter.index <= 0) return;
    await jumpToChapter(chapter.index - 1);
  }

  /// 是否有上一章
  bool get hasPrevChapter {
    final chapter = state.currentChapter;
    return chapter != null && chapter.index > 0;
  }

  /// 是否有下一章
  bool get hasNextChapter {
    final chapter = state.currentChapter;
    final catalog = state.catalog;
    if (chapter == null) return false;
    if (catalog == null) return true; // 未知目录时允许尝试
    return chapter.index < catalog.chapters.length - 1;
  }

  void _saveProgress() {
    final chapter = state.currentChapter;
    if (chapter == null) return;
    final progress = ReadingProgress(
      bookId: chapter.bookId,
      chapterIndex: chapter.index,
      paragraphOffset: state.progress?.paragraphOffset ?? 0,
      scrollOffset: state.progress?.scrollOffset ?? 0,
      pageIndex: state.currentPage,
      updatedAt: DateTime.now(),
    );
    try {
      unawaited(_repository.saveProgress(progress).catchError((_) {}));
      unawaited(_syncBookToShelf(progress));
    } catch (_) {
      // 进度保存失败不影响阅读
    }
  }

  /// 阅读进度同步到书架模型，保持书架进度条与排序字段最新。
  Future<void> _syncBookToShelf(ReadingProgress progress) async {
    final catalogLength = state.catalog?.chapters.length;
    final pageFraction = state.pages.isEmpty
        ? 0.0
        : state.currentPage / state.pages.length;
    final lastChapter = state.currentChapter?.title;
    try {
      final book = await _bookshelfRepo.getById(progress.bookId);
      if (book == null) return;
      final normalizedProgress = (catalogLength != null && catalogLength > 0)
          ? (((progress.chapterIndex + pageFraction) / catalogLength).clamp(0.0, 1.0)).toDouble()
          : book.progress;
      await _bookshelfRepo.save(Book(
        id: book.id,
        name: book.name,
        author: book.author,
        coverUrl: book.coverUrl,
        sourceId: book.sourceId,
        lastChapter: lastChapter ?? book.lastChapter,
        progress: normalizedProgress,
        group: book.group,
        lastReadAt: progress.updatedAt,
      ));
    } catch (_) {
      // 书架同步失败不影响阅读
    }
  }

  /// 页面退出时兜底同步一次书架进度。
  void syncShelfNow() {
    final chapter = state.currentChapter;
    if (chapter == null) return;
    final progress = ReadingProgress(
      bookId: chapter.bookId,
      chapterIndex: chapter.index,
      paragraphOffset: state.progress?.paragraphOffset ?? 0,
      scrollOffset: state.progress?.scrollOffset ?? 0,
      pageIndex: state.currentPage,
      updatedAt: DateTime.now(),
    );
    unawaited(_syncBookToShelf(progress));
  }

  /// 从错误态重试最近一次章节加载。
  void retryLoad() {
    final bookId = _lastBookId;
    if (bookId == null) return;
    unawaited(loadChapter(
      bookId: bookId,
      chapterIndex: _lastChapterIndex,
      sourceId: _lastSourceId ?? 'default',
      detailUrl: _lastDetailUrl,
    ));
  }
}

final readerProvider = NotifierProvider<ReaderNotifier, ReaderState>(() {
  return ReaderNotifier();
});
