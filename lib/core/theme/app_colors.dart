import 'package:flutter/material.dart';

/// E-Ink / Paper 风格色彩体系 — 书棕 + 琥珀 + 纸张质感
class AppColors {
  // ---- 浅色模式 ----
  static const Color background = Color(0xFFFDFBF7);      // 纸白
  static const Color surface = Color(0xFFFFFFFF);          // 卡片纯白
  static const Color textPrimary = Color(0xFF1C1917);      // 暖墨黑
  static const Color textSecondary = Color(0xFF78716C);    // 暖灰棕
  static const Color separator = Color(0xFFE7E5E4);        // 暖分隔线
  static const Color tint = Color(0xFFD97706);             // 琥珀强调
  static const Color tintSoft = Color(0xFFFFF7ED);         // 琥珀淡底
  static const Color success = Color(0xFF16A34A);
  static const Color danger = Color(0xFFDC2626);

  // ---- 深色模式 ----
  static const Color darkBackground = Color(0xFF121212);   // 深墨
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkTextPrimary = Color(0xFFF5F5F4);
  static const Color darkTextSecondary = Color(0xFFA8A29E);
  static const Color darkSeparator = Color(0xFF2A2A2A);
  static const Color darkTint = Color(0xFFF59E0B);         // 亮琥珀

  // ---- 阅读主题（纸感色系）----
  static const Color readDay = Color(0xFFF5F0E8);          // 米纸
  static const Color readDayText = Color(0xFF3B3530);
  static const Color readNight = Color(0xFF121212);         // 深墨夜读
  static const Color readNightText = Color(0xFF8A8A85);
  static const Color readGreen = Color(0xFFE4EAD9);        // 柔护眼
  static const Color readGreenText = Color(0xFF33402E);
  static const Color readSepia = Color(0xFFF3E8D8);        // 羊皮纸
  static const Color readSepiaText = Color(0xFF4A3F35);
}
