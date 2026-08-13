import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import 'purification_rules_page.dart';
import 'reading_stats_page.dart';
import 'webdav_config_page.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../reader/core/pagination/phonetic_annotator.dart';
import '../../../reader/data/models/chapter_model.dart';
import '../../../reader/domain/usecases/auto_switch_source.dart';
import '../../../reader/presentation/pages/book_marks_notes_page.dart';
import '../../data/services/webdav_backup_scheduler.dart';
import '../../domain/usecases/backup_restore.dart';
import '../../domain/usecases/webdav_sync.dart';
import '../providers/purify_pipeline_provider.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
import '../../../book_source/domain/usecases/manage_subscription.dart';
import '../../../bookshelf/data/services/auto_refresh_service.dart';
import '../../../bookshelf/presentation/providers/bookshelf_provider.dart';
import '../../../reader/presentation/providers/reader_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backupRestore = BackupRestore(
      bookshelfRepo: ref.watch(bookshelfRepositoryProvider),
      sourceRepo: ref.watch(bookSourceRepositoryProvider),
    );
    final autoUpdater = BookshelfAutoUpdater(
      readerRepo: ref.watch(readerRepositoryProvider),
      bookshelfRepo: ref.watch(bookshelfRepositoryProvider),
      detailService: ref.watch(bookDetailServiceProvider),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionHeader(title: '数据管理'),
          _GroupCard(children: [
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('导出备份'),
              subtitle: const Text('备份书架、书源数据到 JSON 文件'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final path = await backupRestore.exportBackup();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(path != null ? '备份已保存: $path' : '备份失败')),
                );
              },
            ),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('导出加密备份'),
              subtitle: const Text('口令 AES-GCM 加密，备份含 Cookie 也不怕泄露'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final path = await backupRestore
                    .exportBackup(encrypted: true, context: context);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      path != null ? '加密备份已保存: $path' : '备份未保存',
                    ),
                  ),
                );
              },
            ),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('从备份恢复'),
              subtitle: const Text('支持明文 JSON 与口令加密（.erbackup）备份'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('确认恢复备份'),
                    content: const Text('恢复将覆盖当前全部数据（书架、书源、进度、规则等）。'
                        '明文备份含 Cookie 等敏感信息，加密备份需口令验证，'
                        '请确认来源可信后继续。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续恢复')),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                final result = await backupRestore.restoreBackup(context: context);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(result ?? '操作完成')),
                );
                ref.invalidate(bookshelfListProvider);
                ref.invalidate(bookSourceListProvider);
                ref.invalidate(purifyPipelineProvider);
              },
            ),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('WebDAV 云同步'),
              subtitle: const Text('配置服务器，云端备份与恢复'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const WebDavConfigPage()));
              },
            ),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('上传到 WebDAV'),
              subtitle: const Text('将当前数据备份上传到云端'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final json = await backupRestore.buildBackupJson();
                final result = await WebDavSync().upload(json);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(result ?? '上传成功')),
                );
              },
            ),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('从 WebDAV 恢复'),
              subtitle: const Text('从云端备份恢复数据'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                // 与本地恢复一致：覆盖全部数据前必须确认，避免误触丢失
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('确认从 WebDAV 恢复'),
                    content: const Text('恢复将覆盖当前全部数据（书架、书源、进度、规则等），'
                        '且云端备份包含 Cookie 等敏感信息，请确认来源可信后继续。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('继续恢复'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                final json = await WebDavSync().download();
                if (!context.mounted) return;
                if (json == null || json.startsWith('下载失败')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(json ?? '下载失败')),
                  );
                  return;
                }
                final result = await backupRestore.restoreFromJson(json);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(result ?? '操作完成')),
                );
                ref.invalidate(bookshelfListProvider);
                ref.invalidate(bookSourceListProvider);
                ref.invalidate(purifyPipelineProvider);
              },
            ),
            const _Divider(),
            _AutoBackupTile(backupRestore: backupRestore),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.sync_outlined),
              title: const Text('更新全部书源订阅'),
              subtitle: const Text('刷新所有订阅并同步书源'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final manager = ManageSubscription(
                  bookSourceRepository: ref.read(bookSourceRepositoryProvider),
                );
                final count = await manager.updateAll();
                ref.invalidate(bookSourceListProvider);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('订阅更新完成，新增/更新 $count 个书源')),
                );
              },
            ),
            const _Divider(),
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
            _AutoRefreshTile(updater: autoUpdater),
            const _Divider(),
            const _PhoneticTile(),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('管理净化规则'),
              subtitle: const Text('自定义文本替换规则（正则）'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const PurificationRulesPage()));
              },
            ),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: const Text('阅读统计'),
              subtitle: const Text('查看阅读时长和记录'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingStatsPage()));
              },
            ),
            const _Divider(),
            ListTile(
              leading: const Icon(Icons.bookmarks_outlined),
              title: const Text('书签与笔记'),
              subtitle: const Text('跨书查看和管理全部书签、笔记'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BookMarksNotesPage()),
                );
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

/// 生僻字注音开关：正文中生僻字显示小字拼音，持久化到独立
/// Hive 盒 phonetic_setting（key enabled，默认 false），切换实时生效。
class _PhoneticTile extends StatefulWidget {
  const _PhoneticTile();

  @override
  State<_PhoneticTile> createState() => _PhoneticTileState();
}

class _PhoneticTileState extends State<_PhoneticTile> {
  @override
  void initState() {
    super.initState();
    PhoneticSettings.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    PhoneticSettings.enabled.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PhoneticSettings.enabled.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.font_download_outlined),
      title: const Text('生僻字注音'),
      subtitle: const Text('正文中生僻字显示拼音'),
      value: PhoneticSettings.enabled.value,
      onChanged: (value) => PhoneticSettings.setEnabled(value),
    );
  }
}

/// 自动更新书架设置：0 关闭，其余为间隔小时数。
class _AutoRefreshTile extends StatefulWidget {
  final BookshelfAutoUpdater updater;

  const _AutoRefreshTile({required this.updater});

  @override
  State<_AutoRefreshTile> createState() => _AutoRefreshTileState();
}

class _AutoRefreshTileState extends State<_AutoRefreshTile> {
  int _hours = 0;

  @override
  void initState() {
    super.initState();
    AutoRefreshSettings.load().then((hours) {
      if (mounted) setState(() => _hours = hours);
    });
  }

  Future<void> _pick() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('自动更新书架'),
        children: [
          for (final entry in const {
            0: '关闭',
            1: '每 1 小时',
            6: '每 6 小时',
            24: '每 24 小时',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(
                entry.value,
                style: TextStyle(
                  fontWeight: _hours == entry.key ? FontWeight.w600 : null,
                ),
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    await AutoRefreshSettings.save(selected);
    await AutoRefreshScheduler.restart(widget.updater.updateAll);
    if (mounted) setState(() => _hours = selected);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.update_outlined),
      title: const Text('自动更新书架'),
      subtitle: Text(_hours <= 0 ? '关闭' : '每 $_hours 小时更新全部书籍详情'),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: _pick,
    );
  }
}

/// 自动备份设置：开关 + 间隔选择（每天/每周），变更后重启调度器。
class _AutoBackupTile extends StatefulWidget {
  final BackupRestore backupRestore;

  const _AutoBackupTile({required this.backupRestore});

  @override
  State<_AutoBackupTile> createState() => _AutoBackupTileState();
}

class _AutoBackupTileState extends State<_AutoBackupTile> {
  bool _enabled = false;
  int _intervalHours = WebDavBackupSettings.dailyHours;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await WebDavBackupSettings.isEnabled();
    final intervalHours = await WebDavBackupSettings.intervalHours();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _intervalHours = intervalHours;
    });
  }

  Future<void> _apply({required bool enabled, required int intervalHours}) async {
    await WebDavBackupSettings.save(
      enabled: enabled,
      intervalHours: intervalHours,
    );
    await WebDavBackupScheduler.start(backupRestore: widget.backupRestore);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.cloud_sync_outlined),
          title: const Text('自动备份'),
          subtitle: const Text('按间隔自动上传备份到 WebDAV'),
          value: _enabled,
          onChanged: (value) {
            setState(() => _enabled = value);
            _apply(enabled: value, intervalHours: _intervalHours);
          },
        ),
        if (_enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: WebDavBackupSettings.dailyHours,
                  label: Text('每天'),
                ),
                ButtonSegment(
                  value: WebDavBackupSettings.weeklyHours,
                  label: Text('每周'),
                ),
              ],
              selected: {_intervalHours},
              onSelectionChanged: (selection) {
                final hours = selection.first;
                setState(() => _intervalHours = hours);
                _apply(enabled: _enabled, intervalHours: hours);
              },
            ),
          ),
      ],
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
