import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
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
import '../../../settings/domain/entities/chinese_conversion.dart';

final readerRepositoryProvider = Provider<ReaderRepositoryImpl>((ref) {
  // 注入真实书源仓库：否则默认 _EmptySourceRepo 会让所有章节读取返回占位内容
  final sourceRepo = ref.watch(bookSourceRepositoryProvider);
  // 不在此 watch purifyPipelineProvider：规则 invalidate 时本 provider 会重建
  // 产生新 ReaderRepositoryImpl（其 _pipeline 默认空管线），导致新加载章节跳过
  // 用户正则/JS 规则的降级窗口。净化管线由 ReaderNotifier.build 的 ref.listen
  // 在加载完成后 setPipeline 到稳定不重建的 repo 实例。
  return ReaderRepositoryImpl(sourceRepo: sourceRepo);
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
  final ChineseConversionMode chineseMode;
  /// 当前章节解析后的原始节点（滚动模式直接渲染，不经过分页分段）
  final List<TextNode> nodes;

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
    this.nodes = const [],
    this.chineseMode = ChineseConversionMode.original,
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
    List<TextNode>? nodes,
    ChineseConversionMode? chineseMode,
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
      nodes: nodes ?? this.nodes,
      chineseMode: chineseMode ?? this.chineseMode,
    );
  }
}

class ReaderNotifier extends Notifier<ReaderState> {
  // 用 getter 而非 build 内赋值的 late final：build 可能因依赖 provider
  // 重建（如 purifyPipeline invalidate → readerRepository 重建）重跑，
  // late final 二次赋值会抛 LateInitializationError；getter 无副作用且
  // 每次拿到最新实例。
  ReaderRepositoryImpl get _repository => ref.read(readerRepositoryProvider);
  BookshelfRepository get _bookshelfRepo =>
      ref.read(bookshelfRepositoryProvider);
  final HtmlContentParser _parser = HtmlContentParser();
  String? widgetDetailUrl;
  String? _activeBookId;
  String? _lastBookId;
  int _lastChapterIndex = 0;
  String? _lastSourceId;
  String? _lastDetailUrl;

  /// 请求序号：防止快速切章时旧请求覆盖新章节
  int _loadSeq = 0;

  /// 分页结果缓存：key = 章节 + LayoutConfig 各字段 + 视口尺寸，
  /// 命中时直接返回，避免滑杆拖动/重复进入章节时重复 TextPainter 重排。
  final Map<String, List<PageContent>> _pageCache = {};
  static const int _pageCacheMax = 10;

  /// 当前章节解析后的原始节点（分页与滚动渲染共用，避免重复解析）
  List<TextNode>? _currentNodes;

  /// 真实视口是否已上报（首次打开时为默认 Size(400,600)，延迟分页）
  bool _viewportReported = false;

  /// 进度保存防抖：连续翻页/滚动时合并写入，500ms 内只写最近一次
  Timer? _saveDebounce;
  ReadingProgress? _pendingProgress;

  /// 书架同步串行链：同一本书的读-改-写依次执行，避免旧进度覆盖新进度
  Future<void> _syncChain = Future.value();

  /// 当前书源规则 `@put:` 保存的变量（进入阅读页时从搜索/详情页带入）
  Map<String, String> _variables = const {};

  ChineseConversionMode? _chineseMode;

  @override
  ReaderState build() {
    // 不 watch 会重建本 notifier 的 provider：阅读中的 state（章节/分页/视口）
    // 会在 notifier 重建时整体丢失并重置为默认值，表现为"暂无内容"。净化管线
    // 的加载/更新改用 ref.listen 监听：data 到达时实时 setPipeline 到稳定的
    // readerRepositoryProvider 实例，既能热更新又避免阅读状态丢失。
    ref.listen(purifyPipelineProvider, (_, next) {
      if (next case AsyncData(:final value)) {
        ref.read(readerRepositoryProvider).setPipeline(value);
      }
    });
    return const ReaderState();
  }

  /// 打开新书时清空上一本书残留的内容、目录和请求状态。
  void resetForBook(
    String bookId, {
    String? detailUrl,
    Map<String, String> variables = const {},
  }) {
    _loadSeq++;
    _variables = variables;
    _activeBookId = bookId;
    widgetDetailUrl = detailUrl;
    _lastBookId = bookId;
    _lastChapterIndex = 0;
    _lastSourceId = null;
    _lastDetailUrl = detailUrl;
    _currentNodes = null;
    // 视口是设备属性（尺寸不随书变化）：不重置 _viewportReported 与
    // viewportSize。resetForBook 在 initState 的 microtask 中执行，晚于
    // ReaderPageView postFrame 的 setViewport，若在此重置会覆盖已上报的
    // 视口（_viewportReported=false），导致延迟分页永不触发而显示"暂无内容"。
    // 旋转/窗口变化由 setViewport 按尺寸变化自行处理。
    state = state.copyWith(
      currentChapter: null,
      pages: const [],
      nodes: const [],
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
    Map<String, String> variables = const {},
  }) async {
    final effectiveVariables = variables.isEmpty ? _variables : variables;
    final seq = ++_loadSeq;
    // 切章前立即落盘上一章防抖合并的进度
    unawaited(_flushProgress());
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
        variables: effectiveVariables,
      );
      if (seq != _loadSeq) return; // 已被更新的请求取代

      final mode = await _loadChineseMode();
      final nodes = _parser.parse(
        ChineseConversion.convert(chapter.content, mode),
      );
      _currentNodes = nodes;

      final progress = await _repository.loadProgress(bookId);
      if (seq != _loadSeq) return;

      // 视口未上报真实尺寸（首次打开）时延迟分页：等 setViewport 触发，避免双分页
      final viewportReady = _viewportReported;
      final pages = viewportReady
          ? _paginate(nodes, chapter)
          : const <PageContent>[];
      final pageIndex = progress == null
          ? 0
          : progress.pageIndex
              .clamp(0, pages.isEmpty ? 0 : pages.length - 1)
              .toInt();

      state = state.copyWith(
        currentChapter: chapter,
        nodes: nodes,
        pages: pages,
        currentPage: pageIndex,
        progress: progress,
        isLoading: false,
        errorMessage: null,
        chineseMode: mode,
      );

      // 异步加载目录
      _loadCatalog(
        bookId: bookId,
        sourceId: sourceId,
        detailUrl: detailUrl,
        seq: seq,
        variables: effectiveVariables,
      );

      // 预加载后续 2 章（后台执行，不阻塞后续章节切换）
      // ignore: discarded_futures
      _repository.preloadChapters(
        bookId: bookId,
        startIndex: chapterIndex + 1,
        count: 2,
        sourceId: sourceId,
        detailUrl: detailUrl,
        variables: effectiveVariables,
      );
      if (progress != null) {
        unawaited(_syncBookToShelf(progress));
      }
    } catch (e) {
      if (seq == _loadSeq) {
        _currentNodes = null;
        state = state.copyWith(
          currentChapter: null,
          nodes: const [],
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

  Future<ChineseConversionMode> _loadChineseMode() async {
    final cached = _chineseMode;
    if (cached != null) return cached;
    final box = await Hive.openBox<int>('reader_settings');
    final index = box.get('chineseMode', defaultValue: 0) ?? 0;
    final mode = ChineseConversionMode.values[
        index.clamp(0, ChineseConversionMode.values.length - 1)];
    _chineseMode = mode;
    return mode;
  }

  /// 切换简繁转换并立即重新解析当前章节。
  Future<void> setChineseMode(ChineseConversionMode mode) async {
    _chineseMode = mode;
    final box = await Hive.openBox<int>('reader_settings');
    await box.put('chineseMode', mode.index);
    final chapter = state.currentChapter;
    if (chapter == null) return;
    _pageCache.clear();
    final nodes = _parser.parse(
      ChineseConversion.convert(chapter.content, mode),
    );
    _currentNodes = nodes;
    final pages = _viewportReported
        ? _paginate(nodes, chapter)
        : const <PageContent>[];
    final currentPage = state.currentPage
        .clamp(0, pages.isEmpty ? 0 : pages.length - 1)
        .toInt();
    state = state.copyWith(
      nodes: nodes,
      pages: pages,
      currentPage: currentPage,
      chineseMode: mode,
    );
  }

  /// 分页缓存 key：章节标识 + LayoutConfig 各字段 + 视口尺寸
  String _pageCacheKey(Chapter chapter) {
    final cfg = state.layoutConfig;
    final vp = state.viewportSize;
    return '${chapter.bookId}#${chapter.index}'
        '|fs=${cfg.fontSize}|lh=${cfg.lineHeight}'
        '|ps=${cfg.paragraphSpacing}|hp=${cfg.horizontalPadding}'
        '|fw=${cfg.fontWeight.value}|ff=${cfg.fontFamily ?? ''}'
        '|vp=${vp.width}x${vp.height}';
  }

  /// 使用当前视口与排版配置分页（命中缓存直接返回，避免重复 TextPainter 重排）
  List<PageContent> _paginate(List<TextNode> nodes, Chapter chapter) {
    final key = _pageCacheKey(chapter);
    final cached = _pageCache[key];
    if (cached != null) return cached;

    final vp = state.viewportSize;
    final layout = PageLayout(
      viewWidth: vp.width,
      viewHeight: vp.height,
      config: state.layoutConfig,
    );
    final pages = layout.paginate(nodes);
    _pageCache[key] = pages;
    // 简单 LRU：Map 保持插入序，超限时淘汰最早插入的一条
    if (_pageCache.length > _pageCacheMax) {
      _pageCache.remove(_pageCache.keys.first);
    }
    return pages;
  }

  /// 视口尺寸变化时更新分页（旋转 / 窗口缩放 / 首次打开延迟分页）
  void setViewport(double width, double height) {
    // 仅当已标记且尺寸不变时才跳过：resetForBook 会重置 _viewportReported，
    // 再次打开同尺寸阅读器时（viewportSize 残留）必须重新标记并分页，
    // 否则延迟分页永不触发、页面停留在"暂无内容"
    if (_viewportReported && state.viewportSize.width == width &&
        state.viewportSize.height == height) {
      return;
    }
    _viewportReported = true;
    final nodes = _currentNodes;
    final chapter = state.currentChapter;
    state = state.copyWith(viewportSize: Size(width, height));
    if (nodes == null || nodes.isEmpty || chapter == null) return;
    final pages = _paginate(nodes, chapter);
    // 首次打开（pages 尚未分页）时以保存的进度页码为基准恢复，旋转时保持当前页
    final basePage = state.pages.isEmpty
        ? (state.progress?.pageIndex ?? 0)
        : state.currentPage;
    final clampedPage = basePage
        .clamp(0, pages.isEmpty ? 0 : pages.length - 1)
        .toInt();
    state = state.copyWith(pages: pages, currentPage: clampedPage);
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

  /// 更新排版配置（按旧页码/旧页数比例换算新页码，不再重置到 0）
  void updateLayout(LayoutConfig config) {
    final oldPage = state.currentPage;
    final oldLength = state.pages.length;
    state = state.copyWith(layoutConfig: config);
    final nodes = _currentNodes;
    final chapter = state.currentChapter;
    if (nodes == null || nodes.isEmpty || chapter == null || !_viewportReported) {
      return; // 视口未就绪时仅更新配置，分页由 setViewport 触发
    }
    final pages = _paginate(nodes, chapter);
    final newPage = oldLength <= 0 || pages.isEmpty
        ? 0
        : (oldPage * pages.length / oldLength)
            .round()
            .clamp(0, pages.length - 1)
            .toInt();
    state = state.copyWith(pages: pages, currentPage: newPage);
  }

  /// 切换主题
  void switchTheme(ReaderThemeConfig theme) {
    state = state.copyWith(theme: theme);
  }

  /// 切换阅读模式（各模式使用自己的进度维度）
  void switchMode(ReadingMode mode) {
    if (mode == ReadingMode.page) {
      final pages = state.pages;
      final pageIndex = (state.progress?.pageIndex ?? 0)
          .clamp(0, pages.isEmpty ? 0 : pages.length - 1)
          .toInt();
      state = state.copyWith(readingMode: mode, currentPage: pageIndex);
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
    Map<String, String> variables = const {},
  }) async {
    if (detailUrl == null || detailUrl.isEmpty) return;
    try {
      final catalog = await _repository.getCatalog(
        bookId: bookId,
        sourceId: sourceId,
        detailUrl: detailUrl,
        variables: variables,
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

  /// 进度保存防抖：连续翻页/滚动时合并写入（500ms 内只写最近一次），
  /// 页面退出 / 切章 / syncShelfNow 时立即 flush。
  void _saveProgress() {
    final chapter = state.currentChapter;
    if (chapter == null) return;
    _pendingProgress = ReadingProgress(
      bookId: chapter.bookId,
      chapterIndex: chapter.index,
      paragraphOffset: state.progress?.paragraphOffset ?? 0,
      scrollOffset: state.progress?.scrollOffset ?? 0,
      pageIndex: state.currentPage,
      updatedAt: DateTime.now(),
    );
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flushProgress());
    });
  }

  /// 立即落盘最近一次挂起的进度，并串行同步书架。
  Future<void> _flushProgress() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final progress = _pendingProgress;
    _pendingProgress = null;
    if (progress == null) return;
    try {
      await _repository.saveProgress(progress);
    } catch (_) {
      // 进度保存失败不影响阅读
    }
    unawaited(_syncBookToShelf(progress));
  }

  /// 阅读进度同步到书架模型，保持书架进度条与排序字段最新。
  /// 对同一本书串行化读-改-写，避免旧进度覆盖新进度。
  Future<void> _syncBookToShelf(ReadingProgress progress) {
    // 入队时捕获页面状态，避免串行链上执行时读到已变化的状态
    final pageFraction = state.pages.isEmpty
        ? 0.0
        : state.currentPage / state.pages.length;
    final lastChapter = state.currentChapter?.title;
    _syncChain = _syncChain.then((_) =>
        _doSyncBookToShelf(progress, pageFraction, lastChapter));
    return _syncChain;
  }

  Future<void> _doSyncBookToShelf(
    ReadingProgress progress,
    double pageFraction,
    String? lastChapter,
  ) async {
    final catalogLength = state.catalog?.chapters.length;
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

  /// 页面退出时兜底：先立即落盘挂起的进度，再同步一次书架进度。
  void syncShelfNow() {
    unawaited(_flushProgress());
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
