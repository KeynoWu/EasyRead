import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../reader/data/models/chapter_model.dart';
import '../../../reader/domain/usecases/auto_switch_source.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionHeader(title: '数据管理'),
          _GroupCard(children: [
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清除章节缓存'),
              subtitle: const Text('删除全部已缓存章节，下次阅读重新获取'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final box = await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
                final count = box.length;
                if (!context.mounted) return;
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('清除章节缓存'),
                    content: Text('将删除全部已缓存章节（共 $count 章），确定继续吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                await box.clear();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('章节缓存已清除')),
                );
              },
            ),
          ]),

          const _SectionHeader(title: '阅读'),
          _GroupCard(children: [
            const _AutoSwitchTile(),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('管理净化规则'),
              subtitle: const Text('自定义文本替换规则（正则）'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                await context.push('/settings/purification');
              },
            ),
          ]),

          const _SectionHeader(title: '关于'),
          const _GroupCard(children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('版本'),
              subtitle: Text('v1.0.0'),
            ),
            _Divider(),
            ListTile(
              leading: Icon(Icons.code),
              title: Text('开源许可'),
              subtitle: Text('MIT License'),
            ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 自动换源开关：章节加载失败时自动尝试替代书源
class _AutoSwitchTile extends StatefulWidget {
  const _AutoSwitchTile();

  @override
  State<_AutoSwitchTile> createState() => _AutoSwitchTileState();
}

class _AutoSwitchTileState extends State<_AutoSwitchTile> {
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    AutoSwitchSetting.load().then((value) {
      if (mounted) setState(() => _enabled = value);
    });
  }

  Future<void> _toggle(bool value) async {
    await AutoSwitchSetting.save(value);
    if (mounted) setState(() => _enabled = value);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.swap_horiz),
      title: const Text('自动换源'),
      subtitle: const Text('章节加载失败时自动切换可用书源'),
      value: _enabled,
      onChanged: _toggle,
    );
  }
}

/// iOS Inset Grouped 分组卡片
class _GroupCard extends StatelessWidget {
  final List<Widget> children;

  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 用 Material 承载圆角/背景/阴影，ListTile 的 ink 需要 Material ancestor
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: isDark ? AppColors.darkSurface : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
        child: Column(children: children),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Divider(
      height: 1,
      indent: 52,
      color: isDark ? AppColors.darkSeparator : AppColors.separator,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 16, 6),
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
      ),
    );
  }
}
