import 'dart:async';
import 'dart:convert';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../domain/usecases/auto_switch_source.dart';
import '../providers/reader_provider.dart';
import '../widgets/page_view_widget.dart';
import '../../../../core/router/app_router.dart' show ReaderRouteArgs;
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
  final String? variablesJson;

  const ReaderPage({
    super.key,
    required this.bookId,
    this.sourceId,
    this.detailUrl,
    this.alternativesJson,
    this.variablesJson,
  });

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  /// 缓存 notifier：dispose 阶段 widget.ref 不可用，用此引用收尾同步
  ReaderNotifier? _notifier;

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

  /// 搜索/详情规则 `@put:` 产生的变量，用于目录/正文 URL 的 `@get:{key}`。
  Map<String, String> get _variables {
    final json = widget.variablesJson;
    if (json == null || json.isEmpty) return const {};
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value?.toString() ?? '',
        };
      }
    } catch (_) {}
    return const {};
  }

  /// 本页会话是否已自动换源过：单次失败只自动换一次（防循环），
  /// 后续失败需用户手动换源或重新进入阅读页后才会再次触发
  bool _autoSwitchAttempted = false;

  /// 进入阅读页时的应用亮度，退出时恢复（阅读页存活期间亮度才生效）
  double? _entryBrightness;

  @override
  void initState() {
    super.initState();
    // 缓存 notifier 引用：dispose 阶段 widget 的 ref 已被 Riverpod 3
    // 标记不可用（_assertNotDisposed），但 readerProvider 非 autoDispose
    // 仍存活，缓存的引用可直接调用其方法
    _notifier = ref.read(readerProvider.notifier);
    // 记录进入时的亮度，页面退出时恢复
    ScreenBrightness().application
        .then((value) {
          if (mounted) _entryBrightness = value;
        })
        .catchError((_) {
          // 平台不支持时跳过
        });
    Future.microtask(() async {
      // initState 处于 widget 构建期，Riverpod 禁止在此修改 provider；
      // 延迟到帧后执行（resetForBook 先清残留，再按进度续读）
      ref
          .read(readerProvider.notifier)
          .resetForBook(
            widget.bookId,
            detailUrl: widget.detailUrl,
            variables: _variables,
          );
      // 先恢复持久化的排版/主题/阅读模式，再按进度续读，
      // 避免首次分页使用默认设置后又被覆盖
      await ref.read(readerProvider.notifier).loadPersistedSettings();
      // 读取保存的进度，续读到正确章节
      final repo = ref.read(readerRepositoryProvider);
      final progress = await repo.loadProgress(widget.bookId);
      final startChapter = progress?.chapterIndex ?? 0;
      final sourceId = (widget.sourceId != null && widget.sourceId!.isNotEmpty)
          ? widget.sourceId
          : 'default';
      ref
          .read(readerProvider.notifier)
          .loadChapter(
            bookId: widget.bookId,
            chapterIndex: startChapter,
            sourceId: sourceId!,
            detailUrl: widget.detailUrl,
            variables: _variables,
          );
    });
  }

  @override
  void dispose() {
    // 用缓存引用而非 widget.ref：dispose 阶段 ref 已不可用（Riverpod 3）
    _notifier?.syncShelfNow();
    // 恢复进入阅读页前的亮度（仅阅读页存活期间亮度生效）
    final entry = _entryBrightness;
    if (entry != null) {
      unawaited(
        ScreenBrightness()
            .setApplicationScreenBrightness(entry)
            .catchError((_) {}),
      );
    } else {
      unawaited(
        ScreenBrightness().resetApplicationScreenBrightness().catchError(
          (_) {},
        ),
      );
    }
    super.dispose();
  }

  /// 章节加载失败 → 自动换源：设置开启且有可用替代源时，
  /// 尝试一次自动换源；成功后切换书源并重新加载章节。
  Future<void> _maybeAutoSwitchSource() async {
    if (_autoSwitchAttempted || !mounted) return;
    final enabled = await AutoSwitchSetting.load();
    if (!enabled || !mounted) return;
    final currentSourceId = widget.sourceId ?? '';
    // 存在未尝试的替代源（跳过当前源）才触发
    final hasUntried = _alternatives.any(
      (a) => a.sourceId.isNotEmpty && a.sourceId != currentSourceId,
    );
    if (!hasUntried) return;
    _autoSwitchAttempted = true;

    // 当前源名称用于提示"xx 失效"；查询失败不阻塞自动换源
    var currentName = '当前书源';
    try {
      final currentSource = await ref
          .read(bookSourceRepositoryProvider)
          .getById(currentSourceId);
      if (currentSource != null && currentSource.name.isNotEmpty) {
        currentName = currentSource.name;
      }
    } catch (_) {
      // 忽略：名称查询失败时使用兜底文案
    }
    if (!mounted) return;

    // 与手动换源一致：仅尝试当前启用（且未被删除）的替代源
    List<SourceOption> usableAlternatives = _alternatives;
    try {
      final enabledSources = await ref
          .read(bookSourceRepositoryProvider)
          .getEnabled();
      final enabledIds = {for (final s in enabledSources) s.id};
      usableAlternatives = [
        for (final a in _alternatives)
          if (a.sourceId.isEmpty || enabledIds.contains(a.sourceId)) a,
      ];
    } catch (_) {
      // 查询失败按全部可用处理（自动换源属尽力而为）
    }
    if (!mounted) return;

    final result =
        await AutoSwitchSource(
          repository: ref.read(readerRepositoryProvider),
        ).execute(
          bookId: widget.bookId,
          currentSourceId: currentSourceId,
          currentDetailUrl: widget.detailUrl,
          alternatives: usableAlternatives,
          variables: _variables,
        );
    if (!mounted) return;

    if (result == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前书源不可用，自动换源失败，请手动切换书源')));
      return;
    }

    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('源 $currentName 失效，已自动切换到 ${result.sourceName}')),
    );
    // 经 provider 更新源信息：loadChapter 会更新 notifier 的
    // _lastSourceId/_lastDetailUrl/widgetDetailUrl，后续切章沿用新书源。
    // 从已保存进度续读（与手动换源/重新进入阅读页的语义一致），
    // 目录会随章节加载成功后自动拉取。
    final repo = ref.read(readerRepositoryProvider);
    final progress = await repo.loadProgress(widget.bookId);
    if (!mounted) return;
    final startChapter = progress?.chapterIndex ?? 0;
    ref
        .read(readerProvider.notifier)
        .loadChapter(
          bookId: widget.bookId,
          chapterIndex: startChapter,
          sourceId: result.sourceId,
          detailUrl: result.detailUrl,
          variables: _variables,
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
    final currentSource = await repo.getById(
      chapter.sourceId ?? widget.sourceId ?? '',
    );
    if (!mounted) return;

    final selected = await showModalBottomSheet<SourceOption>(
      context: context,
      builder: (_) => SourceSwitcherSheet(
        currentSourceId: chapter.sourceId ?? widget.sourceId ?? '',
        currentSourceName: currentSource?.name ?? '当前书源',
        alternatives: enabledAlternatives,
      ),
    );
    if (selected != null && mounted && selected.bookId.isNotEmpty) {
      // 切换到新书源（保留替代书源列表，参数做 URL 编码）
      final alts = jsonEncode(
        _alternatives
            .map(
              (a) => {
                'bookId': a.bookId,
                'sourceId': a.sourceId,
                'sourceName': a.sourceName,
                'detailUrl': a.detailUrl,
              },
            )
            .toList(),
      );
      context.pushReplacement(
        '/reader/${Uri.encodeComponent(selected.bookId)}',
        extra: ReaderRouteArgs(
          bookId: selected.bookId,
          sourceId: selected.sourceId,
          detailUrl: selected.detailUrl,
          alternativesJson: alts,
          variablesJson: jsonEncode(_variables),
        ),
      );
    }
  }

  void _openCatalog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ChapterCatalogSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);

    // 章节加载失败（错误态出现）→ 自动换源。
    // _maybeAutoSwitchSource 内部有防循环标记：单次失败只自动换一次，
    // 自动换源后的再次失败（含手动重试）不再触发，需手动换源或重新进入。
    ref.listen<ReaderState>(readerProvider, (previous, next) {
      if (previous?.errorMessage == null && next.errorMessage != null) {
        unawaited(_maybeAutoSwitchSource());
      }
    });

    // 沉浸式阅读：菜单模式或设置面板打开时显示顶栏/底栏（点击正文中间呼出菜单）。
    final showChrome = state.showMenu || state.showSettings;
    final isDarkBg = state.theme.backgroundColor.computeLuminance() < 0.5;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            isDarkBg ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDarkBg ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: state.theme.backgroundColor,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  // 顶栏：菜单模式或设置面板打开时显示（点击正文中间呼出菜单）。
                  // 只保留导航职责：返回 + 章节标题；操作入口在底部工具栏。
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: showChrome
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            color: state.theme.backgroundColor,
                            child: Row(
                              children: [
                                IconButton(
                                  icon: Icon(
                                    Icons.arrow_back,
                                    color: state.theme.textColor,
                                  ),
                                  onPressed: () => context.pop(),
                                ),
                                const Spacer(),
                                if (state.currentChapter != null)
                                  Flexible(
                                    child: Text(
                                      state.currentChapter!.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: state.theme.textColor,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                const Spacer(),
                                // 占位保持标题视觉居中
                                const SizedBox(width: 48),
                              ],
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  const Expanded(
                    child: ReaderPageView(),
                  ),
                ],
              ),
              // 底部工具栏：菜单模式的操作层。上一章/全书进度滑块/下一章
              // + 入口行（目录/设置/换源）。设置面板打开时覆盖在其上方。
              if (state.showMenu)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _buildBottomBar(state),
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
      ),
    );
  }

  /// 底部工具栏：配色跟随阅读主题（深浅自适应），与正文形成层次。
  Widget _buildBottomBar(ReaderState state) {
    final notifier = ref.read(readerProvider.notifier);
    final catalog = state.catalog;
    final chapterCount = catalog?.chapters.length ?? 0;
    final hasCatalog = catalog != null && chapterCount > 0;
    final progress = hasCatalog && state.currentChapter != null
        ? (state.currentChapter!.index + 1) / chapterCount
        : null;
    final fg = state.theme.textColor;

    return Container(
      decoration: BoxDecoration(color: state.theme.backgroundColor),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 行1：章节导航 + 全书进度滑块
          Row(
            children: [
              TextButton(
                onPressed:
                    notifier.hasPrevChapter ? notifier.prevChapter : null,
                child: Text(
                  '上一章',
                  style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.8)),
                ),
              ),
              Expanded(
                child: Slider(
                  value: progress ?? 0,
                  onChanged: progress == null
                      ? null
                      : (v) {
                          // 拖动结束跳章：滑块值映射回 0 基章节索引
                          final target =
                              (v * chapterCount).round().clamp(1, chapterCount);
                          notifier.jumpToChapter(target - 1);
                        },
                ),
              ),
              Text(
                hasCatalog && state.currentChapter != null
                    ? '${state.currentChapter!.index + 1}/$chapterCount'
                    : '-/-',
                style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.7)),
              ),
              TextButton(
                onPressed:
                    notifier.hasNextChapter ? notifier.nextChapter : null,
                child: Text(
                  '下一章',
                  style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.8)),
                ),
              ),
            ],
          ),
          // 行2：功能入口（颜色继承阅读主题前景色）
          IconTheme.merge(
            data: IconThemeData(color: fg.withValues(alpha: 0.85)),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: fg.withValues(alpha: 0.85),
                fontSize: 12,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _MenuRow(
                    icon: Icons.menu_book,
                    label: '目录',
                    onTap: _openCatalog,
                  ),
                  _MenuRow(
                    icon: Icons.tune,
                    label: '设置',
                    onTap: () =>
                        ref.read(readerProvider.notifier).openSettings(),
                  ),
                  if (_alternatives.isNotEmpty)
                    _MenuRow(
                      icon: Icons.swap_horiz,
                      label: '换源',
                      onTap: _openSourceSwitcher,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部工具栏入口：竖排图标 + 文字；颜色继承上层 IconTheme/DefaultTextStyle
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _MenuRow({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
