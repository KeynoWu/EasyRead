import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_brightness/screen_brightness.dart';
import '../../core/pagination/page_layout.dart';
import '../../core/theme/reader_theme.dart';
import '../providers/reader_provider.dart';

class ReaderSettingsPanel extends ConsumerStatefulWidget {
  const ReaderSettingsPanel({super.key});

  @override
  ConsumerState<ReaderSettingsPanel> createState() => _ReaderSettingsPanelState();
}

class _ReaderSettingsPanelState extends ConsumerState<ReaderSettingsPanel> {
  double _brightness = 0.8;
  /// 滑杆拖动中的预览值：onChanged 只更新本地预览，onChangeEnd 才提交重排
  double? _previewFontSize;
  double? _previewLineHeight;

  @override
  void initState() {
    super.initState();
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
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: state.theme.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    // 拖动中只更新本地预览，抬手才触发分页重排，避免逐 tick 重排
                    onChanged: (value) {
                      setState(() => _previewFontSize = value);
                    },
                    onChangeEnd: (value) {
                      _previewFontSize = null;
                      notifier.updateLayout(LayoutConfig(
                        fontSize: value,
                        lineHeight: state.layoutConfig.lineHeight,
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
                    // 拖动中只更新本地预览，抬手才触发分页重排，避免逐 tick 重排
                    onChanged: (value) {
                      setState(() => _previewLineHeight = value);
                    },
                    onChangeEnd: (value) {
                      _previewLineHeight = null;
                      notifier.updateLayout(LayoutConfig(
                        fontSize: state.layoutConfig.fontSize,
                        lineHeight: value,
                      ));
                    },
                  ),
                ),
                const Text('宽松', style: TextStyle(fontSize: 12)),
              ],
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
                notifier.updateLayout(LayoutConfig(
                  fontSize: state.layoutConfig.fontSize,
                  lineHeight: state.layoutConfig.lineHeight,
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
        ],
      ),
    );
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
