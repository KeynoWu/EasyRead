import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/js_template.dart';
import 'package:easy_read/features/search/data/engines/rule_engine.dart';

void main() {
  group('JsTemplateEngine', () {
    const html = '''
      <div class="list">
        <div class="item">
          <img src="http://cover.com/a.jpg">
          <h3><a href="http://book.com/1">书名A</a></h3>
        </div>
      </div>
    ''';

    test('java.get 单选择器取元素文本（@js: 内联）', () {
      const rule = "@js:java.get('tag.h3@tag.a@text')";
      expect(JsTemplateEngine.extract(html, rule), '书名A');
    });

    test('java.get 取属性', () {
      const rule = "@js:java.get('tag.img', 'src')";
      expect(JsTemplateEngine.extract(html, rule), 'http://cover.com/a.jpg');
    });

    test('变量赋值 + 路径变量引用', () {
      const rule = "<js>\npath='class.item';\njava.get('tag.h3@tag.a@text', 'x');\njava.get(path);\n</js>";
      // path 变量应被解析为 class.item → 找到第0个 → text
      final result = JsTemplateEngine.extract(html, rule);
      expect(result, isNotNull);
    });

    test('java.setContent 切换文档', () {
      const rule = "<js>\nc='<span>新内容</span>';\njava.setContent(c);\njava.get('span@text');\n</js>";
      expect(JsTemplateEngine.extract(html, rule), '新内容');
    });

    test('不支持能力返回 null（ajax/eval）', () {
      expect(JsTemplateEngine.extract(html, "<js>java.ajax('http://x');</js>"), isNull);
      expect(JsTemplateEngine.extract(html, "<js>eval('1+1');</js>"), isNull);
    });

    test('非 JS 规则返回 null', () {
      expect(JsTemplateEngine.extract(html, 'tag.h3'), isNull);
    });
  });

  group('RuleEngine JS 集成', () {
    const html = '''
      <div class="item"><img src="http://c/1.jpg"><h3>书名</h3></div>
    ''';

    test('extractText 分流 JS 规则', () {
      expect(RuleEngine.extractText(html, "@js:java.get('tag.h3@text')"), '书名');
    });

    test('getElementText 在元素上下文执行 JS 字段规则', () {
      final items = RuleEngine.extractElements(html, 'div.item');
      expect(items.length, 1);
      final cover = RuleEngine.getElementText(items[0], "@js:java.get('tag.img', 'src')");
      expect(cover, 'http://c/1.jpg');
    });

    test('extractElements 对 JS 规则返回空（列表定位不子集化）', () {
      expect(RuleEngine.extractElements(html, "<js>java.get('div');</js>"), isEmpty);
    });

    test('CSS/JSONPath 不回归', () {
      expect(RuleEngine.extractText(html, 'h3'), '书名');
      expect(RuleEngine.extractText('[{"n": 1}]', r'$[0].n'), '1');
    });
  });
}
