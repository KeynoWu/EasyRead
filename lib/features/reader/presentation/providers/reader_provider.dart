import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/pagination/page_layout.dart';

import '../../core/parser/html_parser.dart';
import '../../core/theme/reader_theme.dart';
import '../../data/repositories/reader_repository_impl.dart';
import '../../domain/entities/chapter.dart';
import '../../domain/entities/reading_progress.dart';

final readerRepositoryProvider = Provider<ReaderRepositoryImpl>((ref) {
  return ReaderRepositoryImpl();
});

/// 阅读器状态
class ReaderState {
  final Chapter? currentChapter;
  final List<PageContent> pages;
  final int currentPage;
  final ReadingProgress? progress;
  final LayoutConfig layoutConfig;
  final ReaderThemeConfig theme;
  final bool isLoading;
  final bool showSettings;

  const ReaderState({
    this.currentChapter,
    this.pages = const [],
    this.currentPage = 0,
    this.progress,
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
    LayoutConfig? layoutConfig,
    ReaderThemeConfig? theme,
    bool? isLoading,
    bool? showSettings,
  }) {
    return ReaderState(
      currentChapter: currentChapter ?? this.currentChapter,
      pages: pages ?? this.pages,
      currentPage: currentPage ?? this.currentPage,
      progress: progress ?? this.progress,
      layoutConfig: layoutConfig ?? this.layoutConfig,
      theme: theme ?? this.theme,
      isLoading: isLoading ?? this.isLoading,
      showSettings: showSettings ?? this.showSettings,
    );
  }
}

class ReaderNotifier extends Notifier<ReaderState> {
  late final ReaderRepositoryImpl _repository;
  final HtmlContentParser _parser = HtmlContentParser();

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
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      final chapter = await _repository.getChapter(
        bookId: bookId,
        chapterIndex: chapterIndex,
        sourceId: sourceId,
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

      // 预加载后续 2 章
      _repository.preloadChapters(
        bookId: bookId,
        startIndex: chapterIndex + 1,
        count: 2,
        sourceId: sourceId,
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
