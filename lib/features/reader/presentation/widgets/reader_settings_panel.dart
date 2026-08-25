import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_brightness/screen_brightness.dart';
import '../../core/pagination/page_layout.dart';
import '../../core/theme/reader_theme.dart';
import '../../../settings/domain/entities/chinese_conversion.dart';
import '../providers/reader_provider.dart';

class ReaderSettingsPanel extends ConsumerStatefulWidget {
  const ReaderSettingsPanel({super.key});

  @override
  ConsumerState<ReaderSettingsPanel> createState() => _ReaderSettingsPanelState();
}

class _ReaderSettingsPanelState extends ConsumerState<ReaderSettingsPanel> {
  double _brightness = 0.8;
  /// 当前设置写入范围（面板打开时从 notifier 回显；切换后后续修改写入对应范围）
  SettingsScope _scope = SettingsScope.global;
  /// 滑杆拖动中的预览值：onChanged 更新本地预览并节流实时重排，
  /// onChangeEnd 落盘最终值
  double? _previewFontSize;
  double? _previewLineHeight;
  double? _previewParagraphSpacing;
  double? _previewHorizontalPadding;
  /// 布局预览节流 Timer：拖动中合并重排（150ms），避免逐 tick 全量分页
  Timer? _previewTimer;

  @override
  void initState() {
    super.initState();
    // 面板打开时按当前范围回显（书本级值已在 state 中优先展示）
    _scope = ref.read(readerProvider.notifier).settingsScope;
    // 进入面板时读取当前应用亮度初始化滑杆
    ScreenBrightness().application.then((value) {
      if (mounted) {
        setState(() => _brightness = value.clamp(0.1, 1.0).toDouble());
      }
    }).catchError((_) {
      // 平台不支持时保持默认值
    });
  }

  @override
  void dispose() {
    // 取消布局预览节流定时器，避免面板关闭后仍触发重排
    _previewTimer?.cancel();
    super.dispose();
  }

  /// 拖动节流：合并 150ms 内的连续拖动，触发一次实时重排预览（不写盘）
  void _scheduleLayoutPreview(VoidCallback apply) {
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 150), apply);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: state.theme.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      // 内容较多：限制面板高度并允许滚动，避免小屏设备底部被裁剪
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 面板头部：返回 + 当前章节标题 + 收起。
              // 顶栏随面板显隐（沉浸式阅读），此处保证隐藏时仍有返回途径。
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.arrow_back,
                      color: state.theme.textColor,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '返回',
                  ),
                  Expanded(
                    child: Text(
                      state.currentChapter?.title ?? '阅读',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: state.theme.textColor,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.keyboard_arrow_down,
                      color: state.theme.textColor,
                    ),
                    onPressed: notifier.closeSettings,
                    tooltip: '收起',
                  ),
                ],
              ),
              const Divider(height: 1),
              const SizedBox(height: 12),
              // 设置范围：决定后续修改持久化到全局还是仅当前书本
              _buildSection(
                title: '设置范围',
                child: SegmentedButton<SettingsScope>(
                  segments: const [
                    ButtonSegment(value: SettingsScope.global, label: Text('全局')),
                    ButtonSegment(value: SettingsScope.book, label: Text('本书')),
                  ],
                  selected: {_scope},
                  onSelectionChanged: (selection) =>
                      _switchScope(selection.first),
                ),
              ),
              const SizedBox(height: 16),
              // 亮度（阅读灯）
              _buildSection(
                title: '亮度',
                child: Slider(
                  value: _brightness,
                  min: 0.1,
                  max: 1.0,
                  onChanged: (value) async {
                    setState(() => _brightness = value);
                    try {
                      await ScreenBrightness().setApplicationScreenBrightness(value);
                    } catch (_) {
                      // 平台不支持时忽略
                    }
                  },
                ),
              ),
              const SizedBox(height: 16),
              // 字号
              _buildSection(
                title: '字号',
                child: Row(
                  children: [
                    const Icon(Icons.text_fields, size: 16),
                    Expanded(
                      child: Slider(
                        value: _previewFontSize ?? state.layoutConfig.fontSize,
                        min: 12,
                        max: 32,
                        divisions: 20,
                        // 拖动中节流实时重排预览（不写盘），抬手落盘最终值
                        onChanged: (value) {
                          setState(() => _previewFontSize = value);
                          _scheduleLayoutPreview(() {
                            // updateLayout 整体替换 layoutConfig：必须透传全部现有字段，
                            // 否则用户已设的段距/边距/字重/衬线会被清空
                            final layout = state.layoutConfig;
                            notifier.updateLayout(
                              LayoutConfig(
                                fontSize: value,
                                lineHeight: layout.lineHeight,
                                paragraphSpacing: layout.paragraphSpacing,
                                horizontalPadding: layout.horizontalPadding,
                                fontWeight: layout.fontWeight,
                                fontFamily: layout.fontFamily,
                              ),
                              persist: false,
                            );
                          });
                        },
                        onChangeEnd: (value) {
                          _previewFontSize = null;
                          _previewTimer?.cancel();
                          final layout = state.layoutConfig;
                          notifier.updateLayout(LayoutConfig(
                            fontSize: value,
                            lineHeight: layout.lineHeight,
                            paragraphSpacing: layout.paragraphSpacing,
                            horizontalPadding: layout.horizontalPadding,
                            fontWeight: layout.fontWeight,
                            fontFamily: layout.fontFamily,
                          ));
                        },
                      ),
                    ),
                    const Icon(Icons.text_fields, size: 24),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 行距
              _buildSection(
                title: '行距',
                child: Row(
                  children: [
                    const Text('紧凑', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _previewLineHeight ?? state.layoutConfig.lineHeight,
                        min: 1.0,
                        max: 2.0,
                        divisions: 10,
                        // 拖动中节流实时重排预览（不写盘），抬手落盘最终值
                        onChanged: (value) {
                          setState(() => _previewLineHeight = value);
                          _scheduleLayoutPreview(() {
                            // updateLayout 整体替换 layoutConfig：必须透传全部现有字段
                            final layout = state.layoutConfig;
                            notifier.updateLayout(
                              LayoutConfig(
                                fontSize: layout.fontSize,
                                lineHeight: value,
                                paragraphSpacing: layout.paragraphSpacing,
                                horizontalPadding: layout.horizontalPadding,
                                fontWeight: layout.fontWeight,
                                fontFamily: layout.fontFamily,
                              ),
                              persist: false,
                            );
                          });
                        },
                        onChangeEnd: (value) {
                          _previewLineHeight = null;
                          _previewTimer?.cancel();
                          final layout = state.layoutConfig;
                          notifier.updateLayout(LayoutConfig(
                            fontSize: layout.fontSize,
                            lineHeight: value,
                            paragraphSpacing: layout.paragraphSpacing,
                            horizontalPadding: layout.horizontalPadding,
                            fontWeight: layout.fontWeight,
                            fontFamily: layout.fontFamily,
                          ));
                        },
                      ),
                    ),
                    const Text('宽松', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 段距
              _buildSection(
                title: '段距',
                child: Row(
                  children: [
                    const Text('紧凑', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _previewParagraphSpacing ?? state.layoutConfig.paragraphSpacing,
                        min: 4,
                        max: 24,
                        divisions: 20,
                        // 拖动中节流实时重排预览（不写盘），抬手落盘最终值
                        onChanged: (value) {
                          setState(() => _previewParagraphSpacing = value);
                          _scheduleLayoutPreview(() {
                            // updateLayout 整体替换 layoutConfig：必须透传全部现有字段
                            final layout = state.layoutConfig;
                            notifier.updateLayout(
                              LayoutConfig(
                                fontSize: layout.fontSize,
                                lineHeight: layout.lineHeight,
                                paragraphSpacing: value,
                                horizontalPadding: layout.horizontalPadding,
                                fontWeight: layout.fontWeight,
                                fontFamily: layout.fontFamily,
                              ),
                              persist: false,
                            );
                          });
                        },
                        onChangeEnd: (value) {
                          _previewParagraphSpacing = null;
                          _previewTimer?.cancel();
                          final layout = state.layoutConfig;
                          notifier.updateLayout(LayoutConfig(
                            fontSize: layout.fontSize,
                            lineHeight: layout.lineHeight,
                            paragraphSpacing: value,
                            horizontalPadding: layout.horizontalPadding,
                            fontWeight: layout.fontWeight,
                            fontFamily: layout.fontFamily,
                          ));
                        },
                      ),
                    ),
                    const Text('宽松', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 页边距
              _buildSection(
                title: '页边距',
                child: Row(
                  children: [
                    const Text('窄', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _previewHorizontalPadding ?? state.layoutConfig.horizontalPadding,
                        min: 8,
                        max: 32,
                        divisions: 24,
                        // 拖动中节流实时重排预览（不写盘），抬手落盘最终值
                        onChanged: (value) {
                          setState(() => _previewHorizontalPadding = value);
                          _scheduleLayoutPreview(() {
                            // updateLayout 整体替换 layoutConfig：必须透传全部现有字段
                            final layout = state.layoutConfig;
                            notifier.updateLayout(
                              LayoutConfig(
                                fontSize: layout.fontSize,
                                lineHeight: layout.lineHeight,
                                paragraphSpacing: layout.paragraphSpacing,
                                horizontalPadding: value,
                                fontWeight: layout.fontWeight,
                                fontFamily: layout.fontFamily,
                              ),
                              persist: false,
                            );
                          });
                        },
                        onChangeEnd: (value) {
                          _previewHorizontalPadding = null;
                          _previewTimer?.cancel();
                          final layout = state.layoutConfig;
                          notifier.updateLayout(LayoutConfig(
                            fontSize: layout.fontSize,
                            lineHeight: layout.lineHeight,
                            paragraphSpacing: layout.paragraphSpacing,
                            horizontalPadding: value,
                            fontWeight: layout.fontWeight,
                            fontFamily: layout.fontFamily,
                          ));
                        },
                      ),
                    ),
                    const Text('宽', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 字重
              _buildSection(
                title: '字重',
                child: SegmentedButton<FontWeight>(
                  segments: const [
                    ButtonSegment(value: FontWeight.w400, label: Text('常规')),
                    ButtonSegment(value: FontWeight.w500, label: Text('中等')),
                    ButtonSegment(value: FontWeight.w700, label: Text('加粗')),
                  ],
                  selected: {state.layoutConfig.fontWeight},
                  onSelectionChanged: (selection) {
                    // updateLayout 整体替换 layoutConfig：必须透传全部现有字段
                    final layout = state.layoutConfig;
                    notifier.updateLayout(LayoutConfig(
                      fontSize: layout.fontSize,
                      lineHeight: layout.lineHeight,
                      paragraphSpacing: layout.paragraphSpacing,
                      horizontalPadding: layout.horizontalPadding,
                      fontWeight: selection.first,
                      fontFamily: layout.fontFamily,
                    ));
                  },
                ),
              ),
              const SizedBox(height: 16),
              // 阅读模式
              _buildSection(
                title: '阅读模式',
                child: SegmentedButton<ReadingMode>(
                  segments: const [
                    ButtonSegment(value: ReadingMode.page, label: Text('翻页')),
                    ButtonSegment(value: ReadingMode.scroll, label: Text('滚动')),
                  ],
                  selected: {state.readingMode},
                  onSelectionChanged: (selection) => notifier.switchMode(selection.first),
                ),
              ),
              const SizedBox(height: 16),
              // 翻页动画（仅翻页模式生效）
              _buildSection(
                title: '翻页动画',
                child: SegmentedButton<PageTurnStyle>(
                  segments: const [
                    ButtonSegment(value: PageTurnStyle.flip, label: Text('仿真')),
                    ButtonSegment(value: PageTurnStyle.slide, label: Text('滑动')),
                    ButtonSegment(value: PageTurnStyle.cover, label: Text('覆盖')),
                  ],
                  selected: {state.pageTurnStyle},
                  onSelectionChanged: (selection) =>
                      notifier.switchPageTurnStyle(selection.first),
                ),
              ),
              const SizedBox(height: 16),
              // 简繁转换
              _buildSection(
                title: '简繁',
                child: SegmentedButton<ChineseConversionMode>(
                  segments: const [
                    ButtonSegment(
                      value: ChineseConversionMode.original,
                      label: Text('原文'),
                    ),
                    ButtonSegment(
                      value: ChineseConversionMode.simplified,
                      label: Text('简体'),
                    ),
                    ButtonSegment(
                      value: ChineseConversionMode.traditional,
                      label: Text('繁体'),
                    ),
                  ],
                  selected: {state.chineseMode},
                  onSelectionChanged: (selection) =>
                      notifier.setChineseMode(selection.first),
                ),
              ),
              const SizedBox(height: 16),
              // 正文字体
              _buildSection(
                title: '正文字体',
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('无衬线')),
                    ButtonSegment(value: true, label: Text('衬线')),
                  ],
                  selected: {state.layoutConfig.fontFamily != null},
                  onSelectionChanged: (selection) {
                    final useSerif = selection.first;
                    // updateLayout 整体替换 layoutConfig：必须透传全部现有字段
                    final layout = state.layoutConfig;
                    notifier.updateLayout(LayoutConfig(
                      fontSize: layout.fontSize,
                      lineHeight: layout.lineHeight,
                      paragraphSpacing: layout.paragraphSpacing,
                      horizontalPadding: layout.horizontalPadding,
                      fontWeight: layout.fontWeight,
                      fontFamily: useSerif ? 'Georgia' : null,
                    ));
                  },
                ),
              ),
              const SizedBox(height: 16),
              // 主题选择
              _buildSection(
                title: '主题',
                child: Wrap(
                  spacing: 8,
                  children: ReaderThemes.themes.map((theme) {
                    final isSelected = state.theme.name == theme.name;
                    return GestureDetector(
                      onTap: () => notifier.switchTheme(theme),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: theme.backgroundColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected ? Colors.blue : Colors.grey.shade300,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Center(
                          child: Text('A', style: TextStyle(color: theme.textColor, fontSize: 16)),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),
              // 恢复默认：排版/主题/阅读模式/翻页动画回退默认值
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('恢复默认设置'),
                        content: const Text('将重置字号、行距、段距、边距、字重、'
                            '字体、主题、阅读模式与翻页动画为默认值（全局）。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('恢复'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      notifier.resetLayoutSettings();
                      if (mounted) setState(() {});
                    }
                  },
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复默认设置'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 切换设置写入范围：仅影响后续持久化目标，state 实时生效逻辑不变。
  /// 切到"本书"且该书尚无自定义值时提示当前实际生效的是全局设置。
  Future<void> _switchScope(SettingsScope scope) async {
    setState(() => _scope = scope);
    ref.read(readerProvider.notifier).setSettingsScope(scope);
    if (scope != SettingsScope.book) return;
    final notifier = ref.read(readerProvider.notifier);
    final bookId = notifier.currentBookId;
    if (bookId == null || bookId.isEmpty) return;
    final hasCustom = await notifier.hasBookSettings(bookId);
    if (!hasCustom && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前使用全局设置，修改将仅应用于本书')),
      );
    }
  }

  Widget _buildSection({required String title, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}
