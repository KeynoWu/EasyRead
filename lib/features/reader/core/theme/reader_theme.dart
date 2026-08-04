import 'package:flutter/material.dart';

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

/// 阅读器主题集合
class ReaderThemes {
  static const List<ReaderThemeConfig> themes = [
    ReaderThemeConfig(name: '日间', backgroundColor: Color(0xFFF5F0E8), textColor: Color(0xFF3C3C3C)),
    ReaderThemeConfig(name: '夜间', backgroundColor: Color(0xFF000000), textColor: Color(0xFF888888)),
    ReaderThemeConfig(name: '护眼绿', backgroundColor: Color(0xFFC7EDCC), textColor: Color(0xFF2C4C3C)),
    ReaderThemeConfig(name: '羊皮纸', backgroundColor: Color(0xFFF5E6C8), textColor: Color(0xFF5C4A3C)),
  ];

  static const ReaderThemeConfig defaultTheme = ReaderThemeConfig(
    name: '日间',
    backgroundColor: Color(0xFFF5F0E8),
    textColor: Color(0xFF3C3C3C),
  );
}
