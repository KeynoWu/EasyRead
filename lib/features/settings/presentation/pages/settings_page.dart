import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'purification_rules_page.dart';
import 'reading_stats_page.dart';
import 'webdav_config_page.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/usecases/backup_restore.dart';
import '../../domain/usecases/webdav_sync.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
import '../../../bookshelf/presentation/providers/bookshelf_provider.dart';
import '../../../reader/presentation/providers/reader_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backupRestore = BackupRestore(
      bookshelfRepo: ref.watch(bookshelfRepositoryProvider),
      sourceRepo: ref.watch(bookSourceRepositoryProvider),
      readerRepo: ref.watch(readerRepositoryProvider),
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
              leading: const Icon(Icons.restore_outlined),
              title: const Text('从备份恢复'),
              subtitle: const Text('从 JSON 备份文件恢复数据'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final result = await backupRestore.restoreBackup();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(result ?? '操作完成')),
                );
                ref.invalidate(bookshelfListProvider);
                ref.invalidate(bookSourceListProvider);
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
              },
            ),
          ]),

          const _SectionHeader(title: '阅读'),
          _GroupCard(children: [
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
          ]),

          const _SectionHeader(title: '关于'),
          _GroupCard(children: [
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('版本'),
              subtitle: Text('v1.0.0'),
            ),
            const _Divider(),
            const ListTile(
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

/// iOS Inset Grouped 分组卡片
class _GroupCard extends StatelessWidget {
  final List<Widget> children;

  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(children: children),
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
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
      ),
    );
  }
}
