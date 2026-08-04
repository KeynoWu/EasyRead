import 'package:flutter/material.dart';
import 'app_colors.dart';

/// E-Ink / Paper 风格主题系统 — 暖色调 + 琥珀强调
class AppTheme {
  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.light(
        primary: AppColors.tint,
        onPrimary: Colors.white,
        secondary: AppColors.textSecondary,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: AppColors.danger,
      ),
    );
    return base.copyWith(
      // 大标题导航栏（iOS Large Title 风格）
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        toolbarHeight: 64,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.separator,
        thickness: 0.5,
        space: 0.5,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      // 列表样式
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSecondary,
        titleTextStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
        subtitleTextStyle: TextStyle(fontSize: 13, color: AppColors.textSecondary),
      ),
      // 按钮
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.tint,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      // 搜索框
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.separator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.separator),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.tint, width: 1.5),
        ),
      ),
      // 底部导航
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.surface,
        selectedItemColor: AppColors.tint,
        unselectedItemColor: AppColors.textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 11),
      ),
    );
  }

  static ThemeData get darkTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.darkBackground,
      colorScheme: ColorScheme.dark(
        primary: AppColors.darkTint,
        onPrimary: Colors.black,
        secondary: AppColors.darkTextSecondary,
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkTextPrimary,
        error: AppColors.danger,
      ),
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: AppColors.darkTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.darkTextPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        toolbarHeight: 64,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.darkSeparator,
        thickness: 0.5,
        space: 0.5,
      ),
      cardTheme: CardThemeData(
        color: AppColors.darkSurface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.darkTextSecondary,
        titleTextStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.darkTextPrimary),
        subtitleTextStyle: TextStyle(fontSize: 13, color: AppColors.darkTextSecondary),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.darkTint,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.darkSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.darkSeparator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.darkSeparator),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.darkTint, width: 1.5),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.darkSurface,
        selectedItemColor: AppColors.darkTint,
        unselectedItemColor: AppColors.darkTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
    );
  }
}
