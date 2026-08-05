import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/rule_engine.dart';

void main() {
  group('RuleEngine 级联选择器（Legado 兼容）', () {
    const listHtml = '''
      <div class="newbox">
        <ul>
          <li><h3><a>第一章书</a></h3><span class="c">详情1</span></li>
          <li><h3><a>第二章书</a></h3><span class="c">详情2</span></li>
        </ul>
      </div>
    ''';

    test('class.0@tag.ul.0@tag.li 级联定位列表项', () {
      final items = RuleEngine.extractElements(listHtml, 'class.newbox.0@tag.ul.0@tag.li');
      expect(items.length, 2);
    });

    test('级联 + text 伪属性提取书名', () {
      final name = RuleEngine.extractText(listHtml, 'tag.li.0@tag.a.0@text');
      expect(name, '第一章书');
    });

    test('extractTextList 级联提取全部标题', () {
      final names = RuleEngine.extractTextList(listHtml, 'class.newbox.0@tag.li@tag.a@text');
      expect(names, ['第一章书', '第二章书']);
    });

    test('getElementText 在元素内级联查询', () {
      final items = RuleEngine.extractElements(listHtml, 'class.newbox.0@tag.ul.0@tag.li');
      expect(items.length, 2);
      final title = RuleEngine.getElementText(items[0], 'tag.h3@tag.a@text');
      expect(title, '第一章书');
    });

    test('ownText 只取自身文本（不含后代）', () {
      const html = '<p>直接文本<span>子文本</span></p>';
      expect(RuleEngine.extractText(html, 'p@ownText'), '直接文本');
      expect(RuleEngine.extractText(html, 'p@text'), '直接文本子文本');
    });

    test('attr 提取与单步 CSS 不回归', () {
      const html = '<a class="d" href="http://x.com/1">详情</a>';
      expect(RuleEngine.extractAttr(html, 'a.d@href'), 'http://x.com/1');
      expect(RuleEngine.extractText(html, 'a.d'), '详情');
    });

    test('选择器属性值内含 @ 不崩溃', () {
      const html = '<a href="a@b.com">链接</a>';
      // 非法选择器按无结果处理，不抛异常
      expect(RuleEngine.extractText(html, 'a[href*="@"]'), isNull);
      expect(RuleEngine.extractElements(html, 'a[href*="@"]'), isEmpty);
    });

    test('id./tag./纯CSS 前缀转换', () {
      const html = '<div id="main"><h3>标题</h3></div>';
      expect(RuleEngine.extractText(html, 'id.main@tag.h3@text'), '标题');
    });
  });


  group('审查修复回归', () {
    test('JSON 值条目 + 相对路径字段规则（.name）', () {
      const json = '[{"name": "书A", "detail": {"url": "http://x/1"}}]';
      final items = RuleEngine.extractElements(json, r'$[*]');
      expect(items.length, 1);
      expect(RuleEngine.getElementText(items[0], '.name'), '书A');
      expect(RuleEngine.getElementText(items[0], 'detail.url'), 'http://x/1');
      expect(RuleEngine.getElementText(items[0], r'$.name'), '书A');
    });

    test('纯 CSS 类名以数字结尾不被误当索引', () {
      const html = '<div class="item2"><h3>标题</h3></div>';
      expect(RuleEngine.extractText(html, 'div.item2'), '标题');
      // 前缀形式索引仍生效
      expect(RuleEngine.extractText(html, 'class.item2'), '标题');
      const listHtml = '<div class="box"><span>a</span><span>b</span></div>';
      expect(RuleEngine.extractText(listHtml, 'tag.span.1@text'), 'b');
    });
  });

}
