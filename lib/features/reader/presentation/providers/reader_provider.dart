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

/// 翻页动画样式（仅影响翻页模式的页面过渡动画）
enum PageTurnStyle { flip, slide, cover }

/// 阅读设置持久化范围：全局（裸 key，默认）或仅当前书本（`bookId|` 前缀 key）。
/// 仅影响写入目标；读取始终是书本级优先、全局兜底。
enum SettingsScope { global, book }

/// 阅读器状态
class ReaderState {
  final Chapter? currentChapter;
  final List<PageContent> pages;
  final int currentPage;

  /// 图片章节的图片 URL 列表（过滤空值）：与 provider 内部 _imageUrlsOf 同逻辑，
  /// 供图片阅读器直接使用，避免重复实现。
  List<String> get imageUrls => [
    for (final node in nodes)
      if (node.type == NodeType.image &&
          node.imageUrl != null &&
          node.imageUrl!.isNotEmpty)
        node.imageUrl!,
  ];
  final ReadingProgress? progress;
  final ChapterCatalog? catalog;
  final LayoutConfig layoutConfig;
  final ReaderThemeConfig theme;
  final bool isLoading;
  final bool showSettings;
  final String? errorMessage;
  final ReadingMode readingMode;
  /// 翻页动画样式
  final PageTurnStyle pageTurnStyle;
  final Size viewportSize;
  final ChineseConversionMode chineseMode;
  /// 当前章节解析后的原始节点（滚动模式直接渲染，不经过分页分段）
  final List<TextNode> nodes;
  /// 当前章节是否为图片/漫画章节（图片节点 ≥ 3 且占比 ≥ 80%）。
  /// 图片章节不走文本分页：pages 保持为空，currentPage 语义 = 当前图片索引。
  final bool isImageChapter;

  const ReaderState({
    this.readingMode = ReadingMode.page,
    this.pageTurnStyle = PageTurnStyle.flip,
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
    this.isImageChapter = false,
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
    PageTurnStyle? pageTurnStyle,
    Size? viewportSize,
    List<TextNode>? nodes,
    bool? isImageChapter,
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
      pageTurnStyle: pageTurnStyle ?? this.pageTurnStyle,
      viewportSize: viewportSize ?? this.viewportSize,
      nodes: nodes ?? this.nodes,
      isImageChapter: isImageChapter ?? this.isImageChapter,
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

  /// 当前设置写入范围（默认全局；换书时由 resetForBook 重置，保证每本书独立）
  SettingsScope _settingsScope = SettingsScope.global;

  /// 当前设置写入范围
  SettingsScope get settingsScope => _settingsScope;

  /// 当前作用书本（阅读页打开时由 resetForBook 设置；无书时为 null）
  String? get currentBookId => _activeBookId;

  static const String _settingsBoxName = 'reader_settings';

  /// 按当前范围生成持久化 key：书本级加 `bookId|` 前缀，全局保持裸名（兼容旧数据）。
  /// 范围为本节但无有效 bookId 时回退全局裸 key，避免丢失写入。
  String _settingsKey(String bareKey) {
    if (_settingsScope == SettingsScope.book) {
      final bookId = _activeBookId;
      if (bookId != null && bookId.isNotEmpty) {
        return '$bookId|$bareKey';
      }
    }
    return bareKey;
  }

  /// 读取设置：书本级（`bookId|key` 前缀）优先，缺失读全局裸 key，再缺失返回 null。
  /// 读取不依赖当前范围——无论面板切到哪个范围，展示的都是生效值。
  dynamic _readSetting(Box<dynamic> box, String bareKey) {
    final bookId = _activeBookId;
    if (bookId != null && bookId.isNotEmpty) {
      final bookValue = box.get('$bookId|$bareKey');
      if (bookValue != null) return bookValue;
    }
    return box.get(bareKey);
  }

  /// 切换设置写入范围（仅影响后续持久化目标，state 实时生效逻辑不变）。
  void setSettingsScope(SettingsScope scope) {
    _settingsScope = scope;
  }

  /// 当前书是否存在书本级自定义设置（用于面板"本书"范围提示）。
  Future<bool> hasBookSettings(String bookId) async {
    final box = await Hive.openBox<dynamic>(_settingsBoxName);
    final prefix = '$bookId|';
    return box.keys
        .any((key) => key is String && key.startsWith(prefix));
  }

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
    // 换书时清空分页缓存（旧书分页文本驻留无意义；换源后 key 已含
    // sourceId 不会串源，此处为整体防御）。
    _pageCache.clear();
    // 换书时设置范围重置为全局、简繁缓存清空：每本书的
    // 范围选择与书本级简繁设置相互独立，互不泄漏。
    _settingsScope = SettingsScope.global;
    _chineseMode = null;
    // 视口是设备属性（尺寸不随书变化）：不重置 _viewportReported 与
    // viewportSize。resetForBook 在 initState 的 microtask 中执行，晚于
    // ReaderPageView postFrame 的 setViewport，若在此重置会覆盖已上报的
    // 视口（_viewportReported=false），导致延迟分页永不触发而显示"暂无内容"。
    // 旋转/窗口变化由 setViewport 按尺寸变化自行处理。
    state = state.copyWith(
      currentChapter: null,
      pages: const [],
      nodes: const [],
      isImageChapter: false,
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
      // 图片章节判定：纯图/漫画章节不走文本分页（pages 保持为空），
      // 图片阅读器直接用 nodes 中的图片 URL 列表，currentPage 语义 = 图片索引
      final isImageChapter = _isImageChapter(nodes);

      final progress = await _repository.loadProgress(bookId);
      if (seq != _loadSeq) return;

      // 视口未上报真实尺寸（首次打开）时延迟分页：等 setViewport 触发，避免双分页
      final viewportReady = _viewportReported;
      final pages = (!isImageChapter && viewportReady)
          ? _paginate(nodes, chapter)
          : const <PageContent>[];
      // 进度属于当前章节才恢复页码：翻章后读回的 progress 可能仍是
      // 上一章的（防抖落盘未完成/上章未写），直接套用会让新章从
      // 随机/末页打开。chapterIndex 不匹配时从首页开始。
      final pageIndex = (progress == null || progress.chapterIndex != chapter.index)
          ? 0
          : _alignPage(
              progress.pageIndex,
              isImageChapter ? _imageUrlsOf(nodes).length : pages.length,
              isImage: isImageChapter,
            );

      state = state.copyWith(
        currentChapter: chapter,
        nodes: nodes,
        isImageChapter: isImageChapter,
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
          isImageChapter: false,
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
    final box = await Hive.openBox<dynamic>(_settingsBoxName);
    // 书本级（`bookId|chineseMode`）优先，缺失读全局裸 key，再缺失回退原文
    final value = _readSetting(box, 'chineseMode');
    final index = (value as num?)?.toInt() ?? 0;
    final mode = ChineseConversionMode.values[
        index.clamp(0, ChineseConversionMode.values.length - 1)];
    _chineseMode = mode;
    return mode;
  }

  /// 恢复持久化的排版/主题/阅读模式设置（进入阅读页时调用一次）。
  /// 每个字段先读书本级（`bookId|` 前缀 key），缺失读全局裸 key（兼容旧数据），
  /// 再缺失回退 state 默认。不传 bookId 时使用 resetForBook 设置的当前书本。
  Future<void> loadPersistedSettings({String? bookId}) async {
    if (bookId != null && bookId.isNotEmpty) {
      _activeBookId = bookId;
    }
    final box = await Hive.openBox<dynamic>(_settingsBoxName);
    final fontSize = (_readSetting(box, 'fontSize') as num?)?.toDouble();
    final lineHeight = (_readSetting(box, 'lineHeight') as num?)?.toDouble();
    final rawFontFamily = _readSetting(box, 'fontFamily') as String?;
    final fontFamily = (rawFontFamily == null || rawFontFamily.isEmpty)
        ? null
        : rawFontFamily;
    final paragraphSpacing =
        (_readSetting(box, 'paragraphSpacing') as num?)?.toDouble();
    final horizontalPadding =
        (_readSetting(box, 'horizontalPadding') as num?)?.toDouble();
    final rawFontWeight = (_readSetting(box, 'fontWeight') as num?)?.toInt();
    final themeName = _readSetting(box, 'theme') as String?;
    final modeIndex = (_readSetting(box, 'readingMode') as num?)?.toInt();
    // 翻页动画样式：兼容 int index 与 name 两种存储格式，缺失/非法回退 flip
    final rawTurnStyle = _readSetting(box, 'pageTurnStyle');
    PageTurnStyle? pageTurnStyle;
    if (rawTurnStyle is num) {
      final idx = rawTurnStyle.toInt();
      if (idx >= 0 && idx < PageTurnStyle.values.length) {
        pageTurnStyle = PageTurnStyle.values[idx];
      }
    } else if (rawTurnStyle is String) {
      for (final style in PageTurnStyle.values) {
        if (style.name == rawTurnStyle) {
          pageTurnStyle = style;
          break;
        }
      }
    }

    // fontWeight 按字重数值匹配（w400=400/w500=500/w700=700），缺失/非法时为 null
    FontWeight? fontWeight;
    if (rawFontWeight != null) {
      for (final weight in FontWeight.values) {
        if (weight.value == rawFontWeight) {
          fontWeight = weight;
          break;
        }
      }
    }

    LayoutConfig? layout;
    if (fontSize != null ||
        lineHeight != null ||
        fontFamily != null ||
        paragraphSpacing != null ||
        horizontalPadding != null ||
        fontWeight != null) {
      layout = LayoutConfig(
        fontSize: fontSize ?? state.layoutConfig.fontSize,
        lineHeight: lineHeight ?? state.layoutConfig.lineHeight,
        paragraphSpacing: paragraphSpacing ?? state.layoutConfig.paragraphSpacing,
        horizontalPadding:
            horizontalPadding ?? state.layoutConfig.horizontalPadding,
        fontWeight: fontWeight ?? state.layoutConfig.fontWeight,
        // 缺失/空串时回退当前值，不覆盖会话内已设的衬线
        fontFamily: fontFamily ?? state.layoutConfig.fontFamily,
      );
    }
    ReaderThemeConfig? theme;
    if (themeName != null) {
      for (final candidate in ReaderThemes.themes) {
        if (candidate.name == themeName) {
          theme = candidate;
          break;
        }
      }
    }
    ReadingMode? mode;
    if (modeIndex != null &&
        modeIndex >= 0 &&
        modeIndex < ReadingMode.values.length) {
      mode = ReadingMode.values[modeIndex];
    }
    if (layout != null || theme != null || mode != null || pageTurnStyle != null) {
      state = state.copyWith(
        layoutConfig: layout ?? state.layoutConfig,
        theme: theme ?? state.theme,
        readingMode: mode ?? state.readingMode,
        pageTurnStyle: pageTurnStyle ?? state.pageTurnStyle,
      );
    }
  }

  void _persistLayoutConfig(LayoutConfig config) {
    // 调用时刻锁定 key 集合：避免异步窗口内 scope/换书导致写错目标
    final values = <String, dynamic>{
      _settingsKey('fontSize'): config.fontSize,
      _settingsKey('lineHeight'): config.lineHeight,
      _settingsKey('paragraphSpacing'): config.paragraphSpacing,
      _settingsKey('horizontalPadding'): config.horizontalPadding,
      _settingsKey('fontWeight'): config.fontWeight.value,
      _settingsKey('fontFamily'): config.fontFamily ?? '',
    };
    unawaited(() async {
      try {
        final box = await Hive.openBox<dynamic>(_settingsBoxName);
        await box.putAll(values);
      } catch (_) {
        // 持久化失败不影响阅读：下次修改时重试
      }
    }());
  }

  void _persistTheme(ReaderThemeConfig theme) {
    final key = _settingsKey('theme');
    unawaited(() async {
      try {
        final box = await Hive.openBox<dynamic>(_settingsBoxName);
        await box.put(key, theme.name);
      } catch (_) {
        // 持久化失败不影响阅读：下次修改时重试
      }
    }());
  }

  void _persistReadingMode(ReadingMode mode) {
    final key = _settingsKey('readingMode');
    unawaited(() async {
      try {
        final box = await Hive.openBox<dynamic>(_settingsBoxName);
        await box.put(key, mode.index);
      } catch (_) {
        // 持久化失败不影响阅读：下次修改时重试
      }
    }());
  }

  void _persistPageTurnStyle(PageTurnStyle style) {
    final key = _settingsKey('pageTurnStyle');
    unawaited(() async {
      try {
        final box = await Hive.openBox<dynamic>(_settingsBoxName);
        await box.put(key, style.index);
      } catch (_) {
        // 持久化失败不影响阅读：下次修改时重试
      }
    }());
  }

  /// 切换翻页动画样式：只换页面过渡动画，不重置当前页（进度维度不变）。
  void switchPageTurnStyle(PageTurnStyle style) {
    state = state.copyWith(pageTurnStyle: style);
    _persistPageTurnStyle(style);
  }

  /// 切换简繁转换并立即重新解析当前章节。
  Future<void> setChineseMode(ChineseConversionMode mode) async {
    _chineseMode = mode;
    final box = await Hive.openBox<dynamic>(_settingsBoxName);
    await box.put(_settingsKey('chineseMode'), mode.index);
    final chapter = state.currentChapter;
    if (chapter == null) return;
    _pageCache.clear();
    final nodes = _parser.parse(
      ChineseConversion.convert(chapter.content, mode),
    );
    _currentNodes = nodes;
    final isImage = _isImageChapter(nodes);
    final pages = (!isImage && _viewportReported)
        ? _paginate(nodes, chapter)
        : const <PageContent>[];
    final imageCount = _imageUrlsOf(nodes).length;
    final currentPage = isImage
        ? (imageCount <= 0
            ? 0
            : state.currentPage.clamp(0, imageCount - 1).toInt())
        : _alignPage(state.currentPage, pages.length);
    state = state.copyWith(
      nodes: nodes,
      isImageChapter: isImage,
      pages: pages,
      currentPage: currentPage,
      chineseMode: mode,
    );
  }

  /// 当前是否横屏双栏（宽 > 高）：仅翻页模式参与双栏（分页宽度减半、翻页步长 2），
  /// 滚动模式不参与。以分页所用视口为唯一判定来源，与渲染层保持一致。
  bool get _isDualColumn => state.viewportSize.width > state.viewportSize.height;

  /// 页码对齐：双栏模式下当前页必须是左栏（偶数页，页 0 起），
  /// 保证"当前页=左栏页、翻页整屏"的语义；竖屏退化为普通 clamp。
  /// 图片章节无双栏语义（不参与文本分页），始终按 1 步长对齐。
  int _alignPage(int page, int length, {bool isImage = false}) {
    var p = page.clamp(0, length <= 0 ? 0 : length - 1).toInt();
    if (_isDualColumn && !isImage) p = (p ~/ 2) * 2;
    return p;
  }

  /// 图片章节判定：图片节点数量 ≥ 3 且占全部节点比例 ≥ 80%（纯图章节）。
  /// 空节点列表不判定为图片章节。
  bool _isImageChapter(List<TextNode> nodes) {
    if (nodes.isEmpty) return false;
    var imageCount = 0;
    for (final node in nodes) {
      if (node.type == NodeType.image) imageCount++;
    }
    return imageCount >= 3 && imageCount / nodes.length >= 0.8;
  }

  /// 提取节点中的图片 URL（过滤空值）：图片章节的"页"即一张图。
  List<String> _imageUrlsOf(List<TextNode> nodes) => [
        for (final node in nodes)
          if (node.type == NodeType.image &&
              node.imageUrl != null &&
              node.imageUrl!.isNotEmpty)
            node.imageUrl!,
      ];

  /// 当前章节可翻页数：图片章节 = 图片数（不走文本分页），文本章节 = 分页页数。
  int get _pageCount =>
      state.isImageChapter ? _imageUrlsOf(state.nodes).length : state.pages.length;

  /// 分页缓存 key：章节标识 + 书源 + LayoutConfig 各字段 + 视口尺寸。
  /// 必须含 sourceId：换源后同 bookId+chapterIndex 会命中旧源正文分页。
  String _pageCacheKey(Chapter chapter) {
    final cfg = state.layoutConfig;
    final vp = state.viewportSize;
    return '${chapter.bookId}#${chapter.index}#${chapter.sourceId ?? ''}'
        '|fs=${cfg.fontSize}|lh=${cfg.lineHeight}'
        '|ps=${cfg.paragraphSpacing}|hp=${cfg.horizontalPadding}'
        '|fw=${cfg.fontWeight.value}|ff=${cfg.fontFamily ?? ''}'
        '|vp=${vp.width}x${vp.height}';
  }

  /// 使用当前视口与排版配置分页（命中缓存直接返回，避免重复 TextPainter 重排）
  List<PageContent> _paginate(List<TextNode> nodes, Chapter chapter) {
    final key = _pageCacheKey(chapter);
    final cached = _pageCache[key];
    if (cached != null) {
      // LRU 刷新：命中即重插到 Map 末尾，保证淘汰总是最久未用项
      _pageCache.remove(key);
      _pageCache[key] = cached;
      return cached;
    }

    final vp = state.viewportSize;
    // 横屏双栏：分页宽度减半，每屏并排渲染两页（左=当前页、右=下一页）。
    // 仅调整传入分页引擎的 viewWidth，分页引擎本身不改。
    final layout = PageLayout(
      viewWidth: vp.width > vp.height ? vp.width / 2 : vp.width,
      viewHeight: vp.height,
      config: state.layoutConfig,
    );
    final pages = layout.paginate(nodes);
    _pageCache[key] = pages;
    // LRU 淘汰：命中已重插到末尾，keys.first 即最久未使用
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
    if (state.isImageChapter) {
      // 图片章节不参与文本分页：仅按图片数对齐当前索引（首次打开恢复进度）
      final basePage = state.pages.isEmpty
          ? (state.progress?.pageIndex ?? 0)
          : state.currentPage;
      final count = _imageUrlsOf(nodes).length;
      state = state.copyWith(
        currentPage: _alignPage(basePage, count, isImage: true),
      );
      return;
    }
    final pages = _paginate(nodes, chapter);
    // 首次打开（pages 尚未分页）时以保存的进度页码为基准恢复，旋转时保持当前页
    final basePage = state.pages.isEmpty
        ? (state.progress?.pageIndex ?? 0)
        : state.currentPage;
    // 双栏模式下对齐到左栏（偶数页），保持"当前页=左栏页"语义
    final clampedPage = _alignPage(basePage, pages.length);
    state = state.copyWith(pages: pages, currentPage: clampedPage);
  }

  /// 翻到下一页（横屏双栏时一次翻一整屏 = 两页，当前页保持左栏；
  /// 图片章节始终一次换一张图）
  void nextPage() {
    final step = (_isDualColumn && !state.isImageChapter) ? 2 : 1;
    final next = _alignPage(
      state.currentPage + step,
      _pageCount,
      isImage: state.isImageChapter,
    );
    if (next != state.currentPage) {
      state = state.copyWith(currentPage: next);
      _saveProgress();
    }
  }

  /// 翻到上一页（横屏双栏时一次回一整屏 = 两页）
  void prevPage() {
    final step = (_isDualColumn && !state.isImageChapter) ? 2 : 1;
    final prev = _alignPage(
      state.currentPage - step,
      _pageCount,
      isImage: state.isImageChapter,
    );
    if (prev != state.currentPage) {
      state = state.copyWith(currentPage: prev);
      _saveProgress();
    }
  }

  /// 跳转到指定页（双栏模式下对齐到目标页所在屏幕的左栏，保证目标页可见）
  void jumpToPage(int page) {
    final count = _pageCount;
    if (page >= 0 && page < count) {
      state = state.copyWith(
        currentPage: _alignPage(page, count, isImage: state.isImageChapter),
      );
      _saveProgress();
    }
  }

  /// 滚动模式位置上报（offset 为 0~1 归一化位置）。
  /// 节流：滚动事件高频触发，差异 < 0.5% 时跳过，避免每秒数十次
  /// copyWith 重建 ReaderState 触发全量 rebuild（进度条精度足够）。
  void updateScrollOffset(double offset) {
    if (state.currentChapter == null || state.readingMode != ReadingMode.scroll) return;
    final prev = state.progress?.scrollOffset ?? 0.0;
    if ((offset - prev).abs() < 0.005) return;
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

  /// 更新排版配置（按旧页码/旧页数比例换算新页码，不再重置到 0；
  /// 图片章节无排版分页，仅持久化配置）
  void updateLayout(LayoutConfig config) {
    final oldPage = state.currentPage;
    final oldLength = _pageCount;
    state = state.copyWith(layoutConfig: config);
    _persistLayoutConfig(config);
    final nodes = _currentNodes;
    final chapter = state.currentChapter;
    if (nodes == null || nodes.isEmpty || chapter == null || !_viewportReported) {
      return; // 视口未就绪时仅更新配置，分页由 setViewport 触发
    }
    if (state.isImageChapter) return; // 图片章节不参与文本分页
    final pages = _paginate(nodes, chapter);
    final newPage = oldLength <= 0 || pages.isEmpty
        ? 0
        : _alignPage(
            (oldPage * pages.length / oldLength).round(),
            pages.length,
          );
    state = state.copyWith(pages: pages, currentPage: newPage);
  }

  /// 切换主题
  void switchTheme(ReaderThemeConfig theme) {
    state = state.copyWith(theme: theme);
    _persistTheme(theme);
  }

  /// 切换阅读模式（各模式使用自己的进度维度；
  /// 图片章节两种模式都进图片阅读器，共用图片索引，仅改模式标记）
  void switchMode(ReadingMode mode) {
    if (state.isImageChapter) {
      state = state.copyWith(readingMode: mode);
      _persistReadingMode(mode);
      return;
    }
    if (mode == ReadingMode.page) {
      final pages = state.pages;
      final pageIndex = _alignPage(state.progress?.pageIndex ?? 0, pages.length);
      state = state.copyWith(readingMode: mode, currentPage: pageIndex);
    } else {
      state = state.copyWith(readingMode: mode, currentPage: 0);
    }
    _persistReadingMode(mode);
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
    // 滚动模式不分页（_pageCount 为 0），进度用 updateScrollOffset
    // 上报的 0~1 归一化滚动位置折算，否则书架进度恒为 0。
    final pageFraction = state.readingMode == ReadingMode.scroll
        ? progress.scrollOffset.clamp(0.0, 1.0)
        : (_pageCount <= 0 ? 0.0 : state.currentPage / _pageCount);
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
