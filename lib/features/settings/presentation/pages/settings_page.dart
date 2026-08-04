import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'purification_rules_page.dart';
import 'reading_stats_page.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/usecases/backup_restore.dart';
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
        children: [
          const _SectionHeader(title: '数据管理'),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('导出备份'),
            subtitle: const Text('备份书架、书源数据到 JSON 文件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final path = await backupRestore.exportBackup();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(path != null ? '备份已保存: $path' : '备份失败')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: const Text('从备份恢复'),
            subtitle: const Text('从 JSON 备份文件恢复数据'),
            trailing: const Icon(Icons.chevron_right),
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
          const Divider(),
          const _SectionHeader(title: '净化规则'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('管理净化规则'),
            subtitle: const Text('自定义文本替换规则（正则）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const PurificationRulesPage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('阅读统计'),
            subtitle: const Text('查看阅读时长和记录'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const ReadingStatsPage()));
            },
          ),
          const Divider(),
          const _SectionHeader(title: '关于'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('版本'),
            subtitle: const Text('v1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('开源许可'),
            subtitle: const Text('MIT License'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
      ),
    );
  }
}
