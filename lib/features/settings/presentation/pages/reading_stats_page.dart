import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/reading_stats.dart';
import '../../domain/usecases/reading_stats_service.dart';

class ReadingStatsPage extends StatefulWidget {
  const ReadingStatsPage({super.key});

  @override
  State<ReadingStatsPage> createState() => _ReadingStatsPageState();
}

class _ReadingStatsPageState extends State<ReadingStatsPage> {
  final _service = ReadingStatsService();
  late Future<ReadingStatsSummary> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _service.getSummary();
  }

  void _reload() {
    setState(() {
      _summaryFuture = _service.getSummary();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('阅读统计')),
      body: FutureBuilder<ReadingStatsSummary>(
        future: _summaryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final summary = snapshot.data ?? const ReadingStatsSummary();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 核心指标卡片
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _StatItem(
                        value: summary.totalSeconds >= 3600
                            ? (summary.totalSeconds / 3600).toStringAsFixed(1)
                            : (summary.totalSeconds / 60).toStringAsFixed(0),
                        label: summary.totalSeconds >= 3600 ? '总阅读(小时)' : '总阅读(分钟)',
                      ),
                      _StatItem(value: '${summary.totalDays}', label: '阅读天数'),
                      _StatItem(
                        value: summary.maxDaySeconds >= 60
                            ? '${(summary.maxDaySeconds / 60).toStringAsFixed(0)}分'
                            : '${summary.maxDaySeconds}秒',
                        label: '单日最长',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('最近 7 天', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              // 最近 7 天柱状图
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _BarChart(days: summary.recentDays),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String value;
  final String label;

  const _StatItem({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.tint)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ],
    );
  }
}

class _BarChart extends StatelessWidget {
  final List<DailyReadingStats> days;

  const _BarChart({required this.days});

  @override
  Widget build(BuildContext context) {
    final maxSeconds = days.fold<int>(0, (max, d) => d.readSeconds > max ? d.readSeconds : max);
    final effectiveMax = maxSeconds == 0 ? 1 : maxSeconds;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: days.map((day) {
        final height = (day.readSeconds / effectiveMax * 120).clamp(4.0, 120.0).toDouble();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: height,
              decoration: BoxDecoration(
                color: day.readSeconds > 0 ? AppColors.tint : AppColors.separator.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _shortDate(day.date),
              style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
            ),
          ],
        );
      }).toList(),
    );
  }

  String _shortDate(String date) {
    final parts = date.split('-');
    if (parts.length == 3) return '${parts[1]}/${parts[2]}';
    return date;
  }
}
