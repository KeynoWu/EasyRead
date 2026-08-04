import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/bookshelf/data/services/txt_importer.dart';

void main() {
  group('TxtImporter', () {
    test('should parse simple chapters', () {
      final content = '''
第一章 开始
这是第一章的内容。

第二章 发展
这是第二章的内容。
''';
      final bytes = utf8.encode(content);
      final (title, chapters) = TxtImporter.parseTxt(Uint8List.fromList(bytes), '测试小说.txt');
      expect(title, '测试小说');
      expect(chapters.length, 2);
      expect(chapters[0].$1, contains('第一章'));
      expect(chapters[0].$2, contains('这是第一章的内容'));
      expect(chapters[1].$1, contains('第二章'));
    });

    test('should handle empty file', () {
      final bytes = <int>[];
      final (title, chapters) = TxtImporter.parseTxt(Uint8List.fromList(bytes), '空.txt');
      expect(chapters.length, 1);
      expect(chapters[0].$2, isEmpty);
    });

    test('should extract title from filename', () {
      final content = '这是内容';
      final bytes = utf8.encode(content);
      final (title, _) = TxtImporter.parseTxt(Uint8List.fromList(bytes), '我的小说.TXT');
      expect(title, '我的小说');
    });
  });
}
