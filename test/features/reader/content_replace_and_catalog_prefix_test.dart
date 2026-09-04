import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/reader/data/repositories/catalog_parser.dart';
import 'package:easy_read/features/reader/data/repositories/content_extractor.dart';

void main() {
  group('P0-8 ruleContent.replaceRegex（Legado 完整规则语义）', () {
    test('纯 ## 删除（跳过提取只替换）', () async {
      final out = await ContentExtractor.applyContentReplaceRegex(
        '##【本章完】',
        '正文A【本章完】正文B',
      );
      expect(out, '正文A正文B');
    });

    test('##pat##rep 替换', () async {
      final out = await ContentExtractor.applyContentReplaceRegex(
        '##错误##（已修正）',
        '这错误一段错误两段',
      );
      expect(out, '这（已修正）一段（已修正）两段');
    });

    test('第四段非空仅首匹配（Legado replaceFirst）', () async {
      final out = await ContentExtractor.applyContentReplaceRegex(
        '##o##0##1',
        'foo boo',
      );
      expect(out, 'f0o boo');
    });

    test('存量兼容：JSON 数组 ["pattern","replacement"]', () async {
      final out = await ContentExtractor.applyContentReplaceRegex(
        '["a","b"]',
        'zacb',
      );
      expect(out, 'zbcb');
    });

    test('存量兼容：pattern||replacement（无 ## 时）', () async {
      final out = await ContentExtractor.applyContentReplaceRegex(
        'a||b',
        'zacb',
      );
      expect(out, 'zbcb');
    });

    test('@js: 完整规则结果即新正文', () async {
      final out = await ContentExtractor.applyContentReplaceRegex(
        '@js:result.replace(/a/g, "b")',
        'aaa',
      );
      expect(out, 'bbb');
    });

    test('空规则返回原文', () async {
      final out =
          await ContentExtractor.applyContentReplaceRegex(null, '原文');
      expect(out, '原文');
    });
  });

  group('P0-10 目录 -/+ 前缀与章节 URL 空兜底', () {
    test('-chapterList 前缀：目录倒序', () async {
      const source = BookSource(
        id: 's',
        name: '源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': '-tag.dd',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
        },
      );
      final chapters = await CatalogParser.parseCatalogPage(
        source,
        '<div><dd><a href="/1">C1</a></dd><dd><a href="/2">C2</a></dd>'
        '<dd><a href="/3">C3</a></dd></div>',
        'https://example.com/book/1',
        const {},
      );
      expect(chapters.map((c) => c.title).toList(), ['C3', 'C2', 'C1']);
      expect(chapters.map((c) => c.url).toList(),
          ['/3', '/2', '/1']);
    });

    test('+ 前缀仅剥除不倒序', () async {
      const source = BookSource(
        id: 's',
        name: '源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': '+tag.dd',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
        },
      );
      final chapters = await CatalogParser.parseCatalogPage(
        source,
        '<div><dd><a href="/1">C1</a></dd><dd><a href="/2">C2</a></dd></div>',
        'https://example.com/book/1',
        const {},
      );
      expect(chapters.map((c) => c.title).toList(), ['C1', 'C2']);
    });

    test('章节 URL 空 → 普通章节用 baseUrl 兜底', () async {
      const source = BookSource(
        id: 's',
        name: '源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'tag.dd',
          'chapterName': 'a',
          'chapterUrl': 'a@data-nope',
        },
      );
      final chapters = await CatalogParser.parseCatalogPage(
        source,
        '<div><dd><a>C1</a></dd></div>',
        'https://example.com/book/1',
        const {},
      );
      expect(chapters.single.url, 'https://example.com/book/1');
    });

    test('章节 URL 空 + 卷节点 → 标题+序号 兜底', () async {
      const source = BookSource(
        id: 's',
        name: '源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'tag.dd',
          'chapterName': 'a',
          'chapterUrl': 'a@data-nope',
          'ruleToc': {'isVolume': 'class.vol'},
        },
      );
      final chapters = await CatalogParser.parseCatalogPage(
        source,
        '<div><dd class="vol"><a>卷一</a></dd>'
        '<dd><a>C1</a></dd></div>',
        'https://example.com/book/1',
        const {},
      );
      expect(chapters.first.url, '卷一0'); // 卷：标题+序号
      expect(chapters.first.isVolume, isTrue);
      expect(chapters.last.url, 'https://example.com/book/1'); // 普通：baseUrl
    });
  });
}
