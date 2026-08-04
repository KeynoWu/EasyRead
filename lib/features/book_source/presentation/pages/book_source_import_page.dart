import 'package:dio/dio.dart';
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 8),
          _ImportButton(
            icon: Icons.file_upload_outlined,
            iconColor: AppColors.tint,
            iconBg: AppColors.tintSoft,
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
            iconColor: AppColors.tint,
            iconBg: AppColors.tintSoft,
            title: '从网络链接导入',
            subtitle: '输入书源订阅地址',
            onTap: () => _showUrlDialog(context, useCase),
          ),
          const SizedBox(height: 12),
          _ImportButton(
            icon: Icons.content_paste,
            iconColor: AppColors.tint,
            iconBg: AppColors.tintSoft,
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
    );
  }

  void _showUrlDialog(BuildContext context, ImportBookSource useCase) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入书源地址'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com/sources.json'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isEmpty) return;
              Navigator.pop(context); // 关闭输入对话框
              debugPrint('[ImportPage] 显示加载指示, url=$url');
              // 网络请求期间显示加载指示与进度，避免"无响应"假象
              final cancelToken = CancelToken();
              var progressText = '连接中...';
              var dialogOpen = true;
              void Function(void Function())? updateDialog;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (dialogContext) => StatefulBuilder(
                  builder: (dialogContext, setState) {
                    updateDialog = setState;
                    return AlertDialog(
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(progressText, textAlign: TextAlign.center),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () {
                            dialogOpen = false;
                            cancelToken.cancel();
                          },
                          child: const Text('取消'),
                        ),
                      ],
                    );
                  },
                ),
              );
              final result = await useCase.fromUrl(
                url,
                cancelToken: cancelToken,
                onProgress: (received, total) {
                  if (!dialogOpen) return;
                  // gzip 响应里 total 可能是压缩大小，received 是解压大小，
                  // 展示总量时用两者较大值，避免出现已下载超过总量。
                  final displayTotal = total > received ? total : received;
                  final text = total > 0
                      ? '已下载 ${(received / 1024 / 1024).toStringAsFixed(1)}MB / ${(displayTotal / 1024 / 1024).toStringAsFixed(1)}MB'
                      : '已下载 ${(received / 1024 / 1024).toStringAsFixed(1)}MB...';
                  updateDialog?.call(() => progressText = text);
                },
              );
              debugPrint('[ImportPage] fromUrl 返回: $result');
              if (!context.mounted) return;
              Navigator.pop(context); // 关闭加载指示
              debugPrint('[ImportPage] 加载指示已关闭');
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
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ImportButton({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 图标
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 22, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
