import 'package:easy_read/features/settings/domain/entities/chinese_conversion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChineseConversion 简繁转换', () {
    test('简体转繁体', () {
      expect(
        ChineseConversion.convert(
          '中国小说',
          ChineseConversionMode.traditional,
        ),
        '中國小説',
      );
    });

    test('繁体转简体', () {
      expect(
        ChineseConversion.convert(
          '繁體中文',
          ChineseConversionMode.simplified,
        ),
        '繁体中文',
      );
    });

    test('原文模式不转换', () {
      const text = '繁體中文 中国';
      expect(
        ChineseConversion.convert(text, ChineseConversionMode.original),
        text,
      );
    });
  });
}
