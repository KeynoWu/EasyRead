import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/rule_engine.dart';

void main() {
  group('RuleEngine', () {
    const sampleHtml = '''
      <div class="book-list">
        <div class="item">
          <h3 class="title">书籍A</h3>
          <span class="author">作者A</span>
          <img class="cover" src="http://example.com/a.jpg">
          <a class="detail" href="http://example.com/a">详情</a>
        </div>
        <div class="item">
          <h3 class="title">书籍B</h3>
          <span class="author">作者B</span>
          <img class="cover" src="http://example.com/b.jpg">
          <a class="detail" href="http://example.com/b">详情</a>
        </div>
      </div>
    ''';

    test('extractText should get text by selector', () {
      final result = RuleEngine.extractText(sampleHtml, 'h3.title');
      expect(result, '书籍A');
    });

    test('extractAttr should get attribute by selector@attr', () {
      final result = RuleEngine.extractAttr(sampleHtml, 'img.cover@src');
      expect(result, 'http://example.com/a.jpg');
    });

    test('extractTextList should get all texts', () {
      final results = RuleEngine.extractTextList(sampleHtml, 'h3.title');
      expect(results.length, 2);
      expect(results[0], '书籍A');
      expect(results[1], '书籍B');
    });

    test('extractElements should get list items', () {
      final items = RuleEngine.extractElements(sampleHtml, 'div.item');
      expect(items.length, 2);
    });

    test('getElementText should extract from element', () {
      final items = RuleEngine.extractElements(sampleHtml, 'div.item');
      final name = RuleEngine.getElementText(items[0], 'h3.title');
      expect(name, '书籍A');
    });

    test('getElementText should extract attribute from element', () {
      final items = RuleEngine.extractElements(sampleHtml, 'div.item');
      final src = RuleEngine.getElementText(items[0], 'img.cover@src');
      expect(src, 'http://example.com/a.jpg');
    });
  });
}
