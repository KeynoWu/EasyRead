import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/subscription_source/data/services/rss_parser.dart';

void main() {
  group('RssParser RSS 2.0', () {
    test('完整解析多条目：标题/链接/时间/作者/描述', () {
      const xml = '''
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>测试源</title>
          <item>
            <title>第一条</title>
            <link>https://example.com/1</link>
            <pubDate>Sun, 06 Nov 1994 08:49:37 GMT</pubDate>
            <author>作者甲</author>
            <description>描述一</description>
          </item>
          <item>
            <title>第二条</title>
            <link>https://example.com/2</link>
            <pubDate>Mon, 07 Nov 1994 09:00:00 +0800</pubDate>
            <description><![CDATA[描述二]]></description>
          </item>
        </channel>
      </rss>
      ''';
      final entries = RssParser.parseRss(xml, sourceName: '测试源');
      expect(entries, hasLength(2));
      expect(entries[0].title, '第一条');
      expect(entries[0].link, 'https://example.com/1');
      expect(entries[0].pubDate, DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(entries[0].author, '作者甲');
      expect(entries[0].description, '描述一');
      expect(entries[0].sourceName, '测试源');
      // +0800 → UTC 前移 8 小时
      expect(entries[1].pubDate, DateTime.utc(1994, 11, 7, 1, 0, 0));
      // CDATA 内容可解析
      expect(entries[1].description, '描述二');
    });

    test('content:encoded 优先于 description', () {
      const xml = '''
      <rss version="2.0">
        <channel>
          <item>
            <title>条目</title>
            <link>https://example.com/a</link>
            <description>摘要内容</description>
            <content:encoded>完整正文内容</content:encoded>
          </item>
        </channel>
      </rss>
      ''';
      final entries = RssParser.parseRss(xml);
      expect(entries, hasLength(1));
      expect(entries.single.description, '完整正文内容');
    });

    test('字段缺失容错：空标题/链接不抛，时间为 null', () {
      const xml = '''
      <rss version="2.0">
        <channel>
          <item>
            <title></title>
          </item>
        </channel>
      </rss>
      ''';
      final entries = RssParser.parseRss(xml);
      expect(entries, hasLength(1));
      expect(entries.single.title, isEmpty);
      expect(entries.single.link, isEmpty);
      expect(entries.single.pubDate, isNull);
      expect(entries.single.author, isNull);
      expect(entries.single.description, isNull);
    });
  });

  group('RssParser Atom', () {
    test('解析 feed.entry：title / link alternate / updated / author / summary', () {
      const xml = '''
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>示例 Feed</title>
        <entry>
          <title>Atom 条目</title>
          <link rel="alternate" href="https://example.com/atom/1"/>
          <link rel="self" href="https://example.com/feed"/>
          <updated>2024-03-15T10:30:00Z</updated>
          <author><name>作者乙</name></author>
          <summary>Atom 摘要</summary>
        </entry>
      </feed>
      ''';
      final entries = RssParser.parseRss(xml, sourceName: '示例 Feed');
      expect(entries, hasLength(1));
      expect(entries.single.title, 'Atom 条目');
      expect(entries.single.link, 'https://example.com/atom/1');
      expect(entries.single.pubDate, DateTime.utc(2024, 3, 15, 10, 30));
      expect(entries.single.author, '作者乙');
      expect(entries.single.description, 'Atom 摘要');
      expect(entries.single.sourceName, '示例 Feed');
    });

    test('无 alternate 链接时回退第一个带 href 的 link', () {
      const xml = '''
      <feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
          <title>无 alternate</title>
          <link rel="enclosure" href="https://example.com/enclosure"/>
          <updated>2024-01-01T00:00:00Z</updated>
        </entry>
      </feed>
      ''';
      final entries = RssParser.parseRss(xml);
      expect(entries.single.link, 'https://example.com/enclosure');
      expect(entries.single.description, isNull);
    });

    test('published 回退于 updated 缺失时', () {
      const xml = '''
      <feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
          <title>用 published</title>
          <link href="https://example.com/p"/>
          <published>2023-06-01T08:00:00+08:00</published>
        </entry>
      </feed>
      ''';
      final entries = RssParser.parseRss(xml);
      expect(entries.single.pubDate, DateTime.utc(2023, 6, 1, 0, 0));
    });
  });

  group('RssParser 容错', () {
    test('坏 XML 返回空列表不抛', () {
      expect(RssParser.parseRss('<rss><channel>'), isEmpty);
      expect(RssParser.parseRss('这不是 XML'), isEmpty);
      expect(RssParser.parseRss(''), isEmpty);
      expect(RssParser.parseRss('<feed><entry></feed>'), isEmpty);
    });

    test('空 feed（无条目）返回空列表', () {
      expect(
        RssParser.parseRss(
            '<rss version="2.0"><channel><title>t</title></channel></rss>'),
        isEmpty,
      );
      expect(
        RssParser.parseRss(
            '<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title></feed>'),
        isEmpty,
      );
    });

    test('非 RSS/Atom 根元素视为无法识别', () {
      expect(RssParser.tryParse('<html><body>hi</body></html>'), isNull);
      expect(RssParser.tryParse('<rss><channel>'), isNull);
      // 合法但无条目的 feed 不是解析失败
      expect(
        RssParser.tryParse(
            '<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title></feed>'),
        isNotNull,
      );
    });

    test('时间多格式解析：ISO8601 / RFC822 / 失败为 null', () {
      // ISO8601
      expect(RssParser.parseDate('1994-11-06T08:49:37Z'),
          DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(RssParser.parseDate('2024-01-15T10:30:00+08:00'),
          DateTime.utc(2024, 1, 15, 2, 30));
      // RFC822 命名时区
      expect(RssParser.parseDate('Sun, 06 Nov 1994 08:49:37 GMT'),
          DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(RssParser.parseDate('Wed, 02 Oct 2002 13:00:00 GMT'),
          DateTime.utc(2002, 10, 2, 13, 0, 0));
      // RFC822 数字偏移
      expect(RssParser.parseDate('06 Nov 1994 08:49:37 +0800'),
          DateTime.utc(1994, 11, 6, 0, 49, 37));
      expect(RssParser.parseDate('06 Nov 1994 08:49:37 PST'),
          DateTime.utc(1994, 11, 6, 16, 49, 37));
      // 两位年份
      expect(RssParser.parseDate('06 Nov 94 08:49:37 GMT'),
          DateTime.utc(1994, 11, 6, 8, 49, 37));
      // 失败 → null
      expect(RssParser.parseDate('not a date'), isNull);
      expect(RssParser.parseDate(''), isNull);
      expect(RssParser.parseDate('   '), isNull);
      expect(RssParser.parseDate(null), isNull);
    });
  });
}
