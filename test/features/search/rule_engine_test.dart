import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/rule_engine.dart';
import 'package:easy_read/features/search/data/engines/rule_parser.dart';

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

    test('getElementText bare text rule returns element own text', () {
      // Legado 裸字段规则：chapterName: 'text' 取元素自身文本
      final items = RuleEngine.extractElements(sampleHtml, 'div.item');
      final titles = RuleEngine.extractElements(items[0].outerHtml, 'h3.title');
      final text = RuleEngine.getElementText(titles.first, 'text');
      expect(text, '书籍A');
    });

    test('getElementText bare attr rule returns element attribute', () {
      // Legado 裸属性规则：chapterUrl: 'href' 取元素自身 href（元素确有该属性）
      final items = RuleEngine.extractElements(sampleHtml, 'div.item');
      final links = RuleEngine.extractElements(items[0].outerHtml, 'a.detail');
      final href = RuleEngine.getElementText(links.first, 'href');
      expect(href, 'http://example.com/a');
    });

    test('getElementText bare tag name falls back to css query', () {
      // 标签名不是属性：chapterName: 'a' 仍是 CSS 子元素查询，不取元素属性
      final items = RuleEngine.extractElements(sampleHtml, 'div.item');
      final name = RuleEngine.getElementText(items[0], 'a');
      expect(name, '详情');
    });

    test('getElementText bare unknown ident returns null', () {
      final items = RuleEngine.extractElements(sampleHtml, 'div.item');
      expect(RuleEngine.getElementText(items[0], 'nonexistent'), isNull);
    });
  });

  group('RuleEngine 组合连接符（Legado && || %%）', () {
    const htmlA = '<div><p class="x">甲</p><p class="y">乙</p></div>';
    const htmlB = '<ul><li>一</li><li>二</li><li>三</li></ul>';

    test('&& 合并各部分结果', () {
      final result = RuleEngine.extractTextList(htmlA, 'p.x&&p.y');
      expect(result, ['甲', '乙']);
    });

    test('|| 首个非空结果短路', () {
      expect(RuleEngine.extractText(htmlA, 'p.z||p.x'), '甲');
      expect(RuleEngine.extractText(htmlA, 'p.z||p.q'), isNull);
    });

    test('%% 按下标交叉合并', () {
      final result = RuleEngine.extractTextList(htmlB, 'li%%li');
      expect(result, ['一', '一', '二', '二', '三', '三']);
    });

    test('extractElements || 短路返回首个命中元素列表', () {
      final items = RuleEngine.extractElements(htmlA, 'div.zz||p.x');
      expect(items.length, 1);
    });
  });

  group('RuleParser 列表规则前缀（Legado bookList -/+）', () {
    test('前缀 - 剥除并标记倒序', () {
      final (rule, reverse) =
          RuleParser.splitListRulePrefix('-class.book_list@tag.li');
      expect(rule, 'class.book_list@tag.li');
      expect(reverse, isTrue);
    });

    test('前缀 + 剥除不倒序', () {
      final (rule, reverse) = RuleParser.splitListRulePrefix('+\$ .list');
      expect(rule, '\$ .list');
      expect(reverse, isFalse);
    });

    test('无前缀原样返回', () {
      final (rule, reverse) = RuleParser.splitListRulePrefix('div.item');
      expect(rule, 'div.item');
      expect(reverse, isFalse);
    });
  });

  group('RuleEngine 伪属性（Legado 裸字段 text/ownText/textNodes/html/all）', () {
    const html = '<div class="wrap">'
        '<p>段落一</p>'
        '直接文本'
        '<script>evil()</script>'
        '<p>段落二</p>'
        '</div>';

    test('ownText 仅取自身直接文本节点', () {
      final item = RuleEngine.extractElements(html, 'div.wrap').first;
      expect(RuleEngine.getElementText(item, 'ownText'), '直接文本');
    });

    test('textNodes 取子文本节点并以换行连接', () {
      final item = RuleEngine.extractElements(html, 'div.wrap').first;
      final text = RuleEngine.getElementText(item, 'textNodes');
      expect(text, isNotNull);
      expect(text!.split('\n'), everyElement(isNot(contains('evil'))));
    });

    test('html 剔除 script/style 后返回内部 HTML', () {
      final item = RuleEngine.extractElements(html, 'div.wrap').first;
      final htmlOut = RuleEngine.getElementText(item, 'html');
      expect(htmlOut, isNot(contains('evil')));
      expect(htmlOut, contains('段落一'));
    });

    test('all 返回完整 outerHtml', () {
      final item = RuleEngine.extractElements(html, 'div.wrap').first;
      final all = RuleEngine.getElementText(item, 'all');
      expect(all, contains('段落二'));
    });
  });
}
