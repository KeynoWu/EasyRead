import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/pagination/page_layout.dart';

import '../../core/parser/html_parser.dart';
import '../../core/theme/reader_theme.dart';
import '../../data/repositories/reader_repository_impl.dart';
import '../../domain/entities/chapter.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/entities/reading_progress.dart';

final readerRepositoryProvider = Provider<ReaderRepositoryImpl>((ref) {
  return ReaderRepositoryImpl();
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
  final ReadingMode readingMode;

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
  });

  ReaderState copyWith({
    Chapter? currentChapter,
    List<PageContent>? pages,
    int? currentPage,
    ReadingProgress? progress,
    ChapterCatalog? catalog,
    LayoutConfig? layoutConfig,
    ReaderThemeConfig? theme,
    bool? isLoading,
    bool? showSettings,
    ReadingMode? readingMode,
  }) {
    return ReaderState(
      currentChapter: currentChapter ?? this.currentChapter,
      pages: pages ?? this.pages,
      currentPage: currentPage ?? this.currentPage,
      progress: progress ?? this.progress,
      catalog: catalog ?? this.catalog,
      layoutConfig: layoutConfig ?? this.layoutConfig,
      theme: theme ?? this.theme,
      isLoading: isLoading ?? this.isLoading,
      showSettings: showSettings ?? this.showSettings,
      readingMode: readingMode ?? this.readingMode,
    );
  }
}

class ReaderNotifier extends Notifier<ReaderState> {
  late final ReaderRepositoryImpl _repository;
  final HtmlContentParser _parser = HtmlContentParser();
  String? widgetDetailUrl;

  @override
  ReaderState build() {
    _repository = ref.watch(readerRepositoryProvider);
    return const ReaderState();
  }

  /// 加载章节
  Future<void> loadChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
  }) async {
    widgetDetailUrl = detailUrl ?? widgetDetailUrl;
    state = state.copyWith(isLoading: true);
    try {
      final chapter = await _repository.getChapter(
        bookId: bookId,
        chapterIndex: chapterIndex,
        sourceId: sourceId,
        detailUrl: detailUrl,
      );
      final nodes = _parser.parse(chapter.content);
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 600,
        config: state.layoutConfig,
      );
      final pages = layout.paginate(nodes);

      final progress = await _repository.loadProgress(bookId);

      state = state.copyWith(
        currentChapter: chapter,
        pages: pages,
        currentPage: progress?.pageIndex ?? 0,
        progress: progress,
        isLoading: false,
      );

      // 异步加载目录
      _loadCatalog(bookId: bookId, sourceId: sourceId, detailUrl: detailUrl);

      // 预加载后续 2 章
      _repository.preloadChapters(
        bookId: bookId,
        startIndex: chapterIndex + 1,
        count: 2,
        sourceId: sourceId,
        detailUrl: detailUrl,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false);
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

  /// 切换设置面板
  void toggleSettings() {
    state = state.copyWith(showSettings: !state.showSettings);
  }

  /// 更新排版配置
  void updateLayout(LayoutConfig config) {
    state = state.copyWith(layoutConfig: config, currentPage: 0);
    if (state.currentChapter != null) {
      final nodes = _parser.parse(state.currentChapter!.content);
      final layout = PageLayout(
        viewWidth: 400,
        viewHeight: 600,
        config: config,
      );
      state = state.copyWith(pages: layout.paginate(nodes));
    }
  }

  /// 切换主题
  void switchTheme(ReaderThemeConfig theme) {
    state = state.copyWith(theme: theme);
  }

  /// 切换阅读模式
  void switchMode(ReadingMode mode) {
    state = state.copyWith(readingMode: mode, currentPage: 0);
  }

  /// 加载章节目录
  Future<void> _loadCatalog({
    required String bookId,
    required String sourceId,
    String? detailUrl,
  }) async {
    if (detailUrl == null || detailUrl.isEmpty) return;
    final catalog = await _repository.getCatalog(
      bookId: bookId,
      sourceId: sourceId,
      detailUrl: detailUrl,
    );
    if (catalog.chapters.isNotEmpty) {
      state = state.copyWith(catalog: catalog);
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
    if (state.currentChapter == null) return;
    final progress = ReadingProgress(
      bookId: state.currentChapter!.bookId,
      chapterIndex: state.currentChapter!.index,
      pageIndex: state.currentPage,
      updatedAt: DateTime.now(),
    );
    _repository.saveProgress(progress);
  }
}

final readerProvider = NotifierProvider<ReaderNotifier, ReaderState>(() {
  return ReaderNotifier();
});
