import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book_source.dart';

class BookSourceCard extends StatelessWidget {
  final BookSource source;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  const BookSourceCard({super.key, required this.source, this.onToggle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // 书源图标
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
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
                      ),
                    ),
                    if (source.bookSourceGroup != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: isDark ? AppColors.darkSeparator : AppColors.separator.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            source.bookSourceGroup!,
                            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 启用开关
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
