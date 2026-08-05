import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/entities/book_source_test_record.dart';

class BookSourceCard extends StatelessWidget {
  final BookSource source;

  /// 检测结果（null = 未检测）
  final BookSourceTestRecord? testRecord;

  /// 多选模式（长按进入）：显示勾选框，点击切换选中
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  const BookSourceCard({
    super.key,
    required this.source,
    this.testRecord,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
    this.onToggle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      color: selected ? AppColors.tint.withValues(alpha: 0.08) : null,
      child: InkWell(
        onTap: selectionMode ? onTap : onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // 多选勾选框 / 书源图标
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected ? AppColors.tint : AppColors.textSecondary,
                    size: 22,
                  ),
                )
              else
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.tintSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    source.enabled ? Icons.link : Icons.link_off,
                    size: 20,
                    color: source.enabled ? AppColors.tint : AppColors.textSecondary,
                  ),
                ),
              const SizedBox(width: 12),
              // 名称 + 分组
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (source.bookSourceGroup != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark ? AppColors.darkSeparator : AppColors.separator.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              source.bookSourceGroup!,
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        _TestStatusBadge(testRecord: testRecord),
                      ],
                    ),
                  ],
                ),
              ),
              // 启用开关（非多选模式）
              if (!selectionMode)
                Switch(
                  value: source.enabled,
                  activeTrackColor: AppColors.tint,
                  onChanged: (_) => onToggle?.call(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 检测状态标记：可用（绿）/ 慢（橙）/ 不可用（红）/ 未检测（灰）
class _TestStatusBadge extends StatelessWidget {
  final BookSourceTestRecord? testRecord;

  const _TestStatusBadge({this.testRecord});

  @override
  Widget build(BuildContext context) {
    final record = testRecord;
    if (record == null) {
      return Text(
        '未检测',
        style: TextStyle(fontSize: 11, color: AppColors.textSecondary.withValues(alpha: 0.7)),
      );
    }
    final color = record.usable
        ? (record.isSlow ? Colors.orange : Colors.green)
        : Colors.redAccent;
    final label = record.usable
        ? (record.isSlow ? '慢 ${record.responseTimeMs}ms' : '${record.responseTimeMs}ms')
        : '不可用';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
