import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/services/source_subscription_store.dart';
import '../../domain/usecases/import_book_source.dart';
import '../../domain/usecases/parse_book_source_rule.dart';
import '../providers/book_source_provider.dart';

class BookSourceImportPage extends ConsumerWidget {
  const BookSourceImportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(bookSourceRepositoryProvider);
    final parser = ParseBookSourceRule();
    final useCase = ImportBookSource(
      repository: repo,
      parser: parser,
      // Hive 持久订阅盒（§三-9）：URL 导入成功即记录订阅，源列表页可一键刷新
      subscriptionStore: SourceSubscriptionStore(),
    );

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
              _handleResult(context, ref, result);
            },
          ),
          const SizedBox(height: 12),
          _ImportButton(
            icon: Icons.link,
            iconColor: AppColors.tint,
            iconBg: AppColors.tintSoft,
            title: '从网络链接导入',
            subtitle: '输入书源订阅地址',
            onTap: () => _showUrlDialog(context, ref, useCase),
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
              _handleResult(context, ref, result);
            },
          ),
        ],
      ),
    );
  }

  /// 校验 http/https 且 host 非空
  static bool _isValidHttpUrl(String input) {
    final uri = Uri.tryParse(input);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Future<void> _showUrlDialog(
    BuildContext context,
    WidgetRef ref,
    ImportBookSource useCase,
  ) async {
    final controller = TextEditingController();
    try {
      await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入书源地址'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com/sources.json'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isEmpty) return;
              if (!_isValidHttpUrl(url)) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('请输入有效的 http/https 地址')),
                );
                return;
              }
              Navigator.pop(dialogContext); // 关闭输入对话框
              debugPrint('[ImportPage] 显示加载指示, url=$url');
              // 网络请求期间显示加载指示与进度，避免"无响应"假象
              final cancelToken = CancelToken();
              var progressText = '连接中...';
              var dialogOpen = true;
              var lockedTotal = 0; // 进度分母（锁定后固定，仅 gzip 超头时单调跟随）
              var hasTotal = false;
              void Function(void Function())? updateDialog;
              BuildContext? loadingContextRef;
              showDialog(
                // 用页面级 context（_showUrlDialog 的参数）打开加载指示，
                // 不能用输入对话框的 dialogContext（已 pop，await 后不可用）
                context: context,
                barrierDismissible: false,
                builder: (loadingContext) => StatefulBuilder(
                  builder: (loadingContext, setState) {
                    loadingContextRef = loadingContext;
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
                            Navigator.pop(loadingContext);
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
                  // 分母固定：首次收到有效 total 后锁定，不再变化。
                  // （gzip 响应时 received 为解压后大小，可能超过压缩的
                  // total，此时分子超分母是正常现象，分母保持服务器总量）
                  if (total > 0 && !hasTotal) {
                    hasTotal = true;
                    lockedTotal = total;
                  }
                  final text = hasTotal
                      ? '已下载 ${(received / 1024 / 1024).toStringAsFixed(1)}MB / ${(lockedTotal / 1024 / 1024).toStringAsFixed(1)}MB'
                      : '已下载 ${(received / 1024 / 1024).toStringAsFixed(1)}MB...';
                  updateDialog?.call(() => progressText = text);
                },
              );
              debugPrint('[ImportPage] fromUrl 返回: $result');
              // 用页面级 context 判断存活（输入对话框的 context 已失效）
              if (!context.mounted) return;
              if (dialogOpen &&
                  loadingContextRef != null &&
                  loadingContextRef!.mounted) {
                Navigator.pop(loadingContextRef!); // 关闭加载指示
              }
              debugPrint('[ImportPage] 加载指示已关闭');
              if (!context.mounted) return;
              _handleResult(context, ref, result);
            },
            child: const Text('导入'),
          ),
        ],
      ),
      );
    } finally {
      // 对话框 pop 后 TextField 元素仍在路由退出动画中（~300ms），
      // 立即 dispose 会让下一帧 didUpdateWidget 对已释放 controller
      // 加监听而触发 debugAssertNotDisposed 崩溃。延迟到动画结束后释放；
      // 局部短生命周期对象，延迟无副作用。
      Future.delayed(const Duration(milliseconds: 500), controller.dispose);
    }
  }

  void _handleResult(BuildContext context, WidgetRef ref, dynamic result) {
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
        // 刷新书源列表：导入前 provider 可能已有缓存，不失效则列表停留在旧数据
        ref.invalidate(bookSourceListProvider);
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
