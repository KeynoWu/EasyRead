import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../features/search/domain/entities/search_result.dart';

/// 换源面板
class SourceSwitcherSheet extends StatelessWidget {
  final String currentSourceId;
  final String currentSourceName;
  final List<SourceOption> alternatives;

  const SourceSwitcherSheet({
    super.key,
    required this.currentSourceId,
    required this.currentSourceName,
    required this.alternatives,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('切换书源', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.check, color: AppColors.success),
                  title: Text(currentSourceName),
                  subtitle: const Text('当前书源'),
                ),
                for (final alt in alternatives)
                  ListTile(
                    leading: const Icon(Icons.swap_horiz, color: AppColors.tint),
                    title: Text(alt.sourceName),
                    subtitle: const Text('点击切换'),
                    onTap: () => Navigator.pop(context, alt),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
