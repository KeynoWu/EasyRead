import 'package:pinyin/pinyin.dart';

/// 正文简繁转换模式。
enum ChineseConversionMode { original, simplified, traditional }

class ChineseConversion {
  static String convert(String text, ChineseConversionMode mode) {
    switch (mode) {
      case ChineseConversionMode.simplified:
        return ChineseHelper.convertToSimplifiedChinese(text);
      case ChineseConversionMode.traditional:
        return ChineseHelper.convertToTraditionalChinese(text);
      case ChineseConversionMode.original:
        return text;
    }
  }
}
