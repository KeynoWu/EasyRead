import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

/// 阅读器主题预设
class ReaderThemeConfig {
  final String name;
  final Color backgroundColor;
  final Color textColor;
  final Color? statusBarColor;

  const ReaderThemeConfig({
    required this.name,
    required this.backgroundColor,
    required this.textColor,
    this.statusBarColor,
  });
}

/// 阅读器主题集合 — 纸感色系
class ReaderThemes {
  static const List<ReaderThemeConfig> themes = [
    ReaderThemeConfig(name: '日间', backgroundColor: AppColors.readDay, textColor: AppColors.readDayText),
    ReaderThemeConfig(name: '夜间', backgroundColor: AppColors.readNight, textColor: AppColors.readNightText),
    ReaderThemeConfig(name: '护眼绿', backgroundColor: AppColors.readGreen, textColor: AppColors.readGreenText),
    ReaderThemeConfig(name: '羊皮纸', backgroundColor: AppColors.readSepia, textColor: AppColors.readSepiaText),
  ];

  static const ReaderThemeConfig defaultTheme = ReaderThemeConfig(
    name: '日间',
    backgroundColor: AppColors.readDay,
    textColor: AppColors.readDayText,
  );
}
