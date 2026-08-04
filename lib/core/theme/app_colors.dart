import 'package:flutter/material.dart';

/// iOS 风格色彩体系 — 低饱和度中性色 + 极简点缀
class AppColors {
  // 通用
  static const Color background = Color(0xFFF2F2F7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF1C1C1E);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color separator = Color(0xFFC6C6C8);
  static const Color tint = Color(0xFF007AFF);

  // 深色模式
  static const Color darkBackground = Color(0xFF000000);
  static const Color darkSurface = Color(0xFF1C1C1E);
  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFF8E8E93);
  static const Color darkSeparator = Color(0xFF38383A);
  static const Color darkTint = Color(0xFF0A84FF);

  // 阅读主题
  static const Color readBackground = Color(0xFFF5F0E8);
  static const Color readDarkBackground = Color(0xFF000000);
  static const Color readGreen = Color(0xFFC7EDCC);
  static const Color readParchment = Color(0xFFF5E6C8);
}
