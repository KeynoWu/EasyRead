import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/usecases/import_book_source.dart';
import '../../domain/usecases/parse_book_source_rule.dart';
import '../providers/book_source_provider.dart';

class BookSourceImportPage extends ConsumerWidget {
  const BookSourceImportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(bookSourceRepositoryProvider);
    final parser = ParseBookSourceRule();
    final useCase = ImportBookSource(repository: repo, parser: parser);

    return Scaffold(
      appBar: AppBar(title: const Text('导入书源')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ImportButton(
              icon: Icons.file_upload_outlined,
              title: '从本地文件导入',
              subtitle: '支持 JSON 格式书源文件',
              onTap: () async {
                final result = await useCase.fromFile();
                if (!context.mounted) return;
                _handleResult(context, result);
              },
            ),
            const SizedBox(height: 12),
            _ImportButton(
              icon: Icons.link,
              title: '从网络链接导入',
              subtitle: '输入书源订阅地址',
              onTap: () => _showUrlDialog(context, useCase),
            ),
            const SizedBox(height: 12),
            _ImportButton(
              icon: Icons.content_paste,
              title: '从剪贴板导入',
              subtitle: '粘贴书源 JSON 内容',
              onTap: () async {
                final result = await useCase.fromClipboard();
                if (!context.mounted) return;
                _handleResult(context, result);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showUrlDialog(BuildContext context, ImportBookSource useCase) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入书源地址'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/sources.json',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final result = await useCase.fromUrl(controller.text);
              if (!context.mounted) return;
              _handleResult(context, result);
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _handleResult(BuildContext context, dynamic result) {
    if (!context.mounted) return;
    result.fold(
      (error) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      ),
      (sources) {
        final count = sources is List ? sources.length : 1;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功导入 $count 个书源')),
        );
        if (context.mounted) Navigator.pop(context);
      },
    );
  }
}

class _ImportButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ImportButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 32, color: AppColors.tint),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Text(subtitle, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
