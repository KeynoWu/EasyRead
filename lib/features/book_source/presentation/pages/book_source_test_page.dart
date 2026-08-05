import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/usecases/batch_test_book_sources.dart';
import '../../domain/usecases/test_book_source.dart';
import '../providers/book_source_provider.dart';

/// 批量检测书源页：进入自动开始，展示实时进度，支持取消。
class BookSourceTestPage extends ConsumerStatefulWidget {
  const BookSourceTestPage({super.key});

  @override
  ConsumerState<BookSourceTestPage> createState() => _BookSourceTestPageState();
}

class _BookSourceTestPageState extends ConsumerState<BookSourceTestPage> {
  final CancelToken _cancelToken = CancelToken();
  bool _running = true;
  bool _cancelled = false;

  int _done = 0;
  int _total = 0;
  int _usable = 0;
  int _unusable = 0;
  String _currentName = '';
  String _currentStatus = '';
  BatchTestSummary? _summary;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final repo = ref.read(bookSourceRepositoryProvider);
    final store = ref.read(bookSourceTestStoreProvider);
    final batch = BatchTestBookSources(
      tester: TestBookSource(),
      store: store,
    );
    final sources = await repo.getAll();
    if (!mounted) return;
    setState(() {
      _total = sources
          .where((s) =>
              s.enabled && s.searchUrl != null && s.bookListRule != null)
          .length;
    });

    final summary = await batch.run(
      sources: sources,
      cancelToken: _cancelToken,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _done = progress.done;
          _currentName = progress.current.name;
          _currentStatus = progress.result.usable
              ? '可用 · ${progress.result.responseTimeMs}ms'
              : '不可用 · ${progress.result.error ?? '解析失败'}';
          if (progress.result.usable) {
            _usable++;
          } else {
            _unusable++;
          }
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _summary = summary;
      _usable = summary.usable;
      _unusable = summary.unusable;
    });
  }

  void _stop() {
    _cancelToken.cancel();
    setState(() => _cancelled = true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? AppColors.darkTextPrimary : AppColors.textPrimary;
    const subColor = AppColors.textSecondary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('批量检测书源'),
        actions: [
          if (_running)
            TextButton(
              onPressed: _stop,
              child: const Text('停止'),
            ),
        ],
      ),
      body: _running ? _buildProgress(titleColor, subColor) : _buildSummary(titleColor, subColor),
    );
  }

  Widget _buildProgress(Color titleColor, Color subColor) {
    final progress = _total == 0 ? 0.0 : _done / _total;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('检测进度', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: titleColor)),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: progress.clamp(0.0, 1.0), minHeight: 8, borderRadius: BorderRadius.circular(4)),
          const SizedBox(height: 8),
          Text('$_done / $_total', style: TextStyle(color: subColor, fontSize: 13)),
          const SizedBox(height: 24),
          Text('当前：$_currentName', style: TextStyle(color: titleColor, fontSize: 15)),
          const SizedBox(height: 4),
          Text(_currentStatus, style: TextStyle(color: subColor, fontSize: 13)),
          const SizedBox(height: 32),
          Row(
            children: [
              _StatChip(label: '可用', value: '$_usable', color: Colors.green),
              const SizedBox(width: 12),
              _StatChip(label: '不可用', value: '$_unusable', color: Colors.redAccent),
            ],
          ),
          const Spacer(),
          if (_cancelled)
            Text('正在停止…', style: TextStyle(color: subColor, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildSummary(Color titleColor, Color subColor) {
    final summary = _summary;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.task_alt, size: 56, color: summary != null && summary.unusable == 0 ? Colors.green : AppColors.tint),
          const SizedBox(height: 12),
          Text('检测完成', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: titleColor)),
          const SizedBox(height: 24),
          _SummaryRow(label: '检测书源', value: '${summary?.total ?? _done}'),
          _SummaryRow(label: '可用', value: '${summary?.usable ?? _usable}', color: Colors.green),
          _SummaryRow(label: '不可用', value: '${summary?.unusable ?? _unusable}', color: Colors.redAccent),
          if ((summary?.skipped ?? 0) > 0) _SummaryRow(label: '跳过（无搜索能力/已禁用）', value: '${summary?.skipped}'),
          const Spacer(),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryRow({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 15, color: AppColors.textSecondary)),
          Text(value,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: color ?? AppColors.textPrimary)),
        ],
      ),
    );
  }
}
