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
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(source.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    if (source.bookSourceGroup != null)
                      Text(source.bookSourceGroup!, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Switch(
                value: source.enabled,
                onChanged: (_) => onToggle?.call(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
