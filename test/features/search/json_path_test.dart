import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/json_path.dart';
import 'package:easy_read/features/search/data/engines/rule_engine.dart';

void main() {
  group('JsonPathEngine', () {
    const json = '''
    {
      "data": [
        {"name": "书籍A", "author": "作者A", "url": "http://a.com/1"},
        {"name": "书籍B", "author": "作者B", "url": "http://a.com/2"}
      ],
      "book_data": ["缓存1", "缓存2"],
      "nested": {"list": [{"name": "深层书"}]}
    }
    ''';

    test(r'基本键路径 $.data[*].name', () {
      final names = JsonPathEngine.queryString(json, r'$.data[*].name');
      expect(names, ['书籍A', '书籍B']);
    });

    test(r'索引路径 $.data[0].name', () {
      final name = JsonPathEngine.queryString(json, r'$.data[0].name');
      expect(name, ['书籍A']);
    });

    test(r'递归下降 $..name 收集所有层级', () {
      final names = JsonPathEngine.queryString(json, r'$..name');
      expect(names, containsAll(['书籍A', '书籍B', '深层书']));
      expect(names.length, 3);
    });

    test('Legado && 组合：前者空则用后者', () {
      final result = JsonPathEngine.queryString(
          json, r'$.data[*].non_exist&&$.book_data[0]');
      expect(result, ['缓存1']);
    });

    test('Legado && 组合：全非空顺序拼接（AnalyzeByJSonPath getList）', () {
      final result =
          JsonPathEngine.queryString(json, r'$.data[*].name&&$.book_data[0]');
      expect(result, ['书籍A', '书籍B', '缓存1']);
    });

    test('Legado || 组合：首个非空即止', () {
      final result = JsonPathEngine.queryString(
          json, r'$.data[*].name||$.book_data[0]');
      expect(result, ['书籍A', '书籍B']);
      final fallback = JsonPathEngine.queryString(
          json, r'$.data[*].non_exist||$.book_data[0]');
      expect(fallback, ['缓存1']);
    });

    test('P1-3 JSON 内容 + 裸规则默认走 JSONPath（Legado isJSON）', () {
      // 无 $ 前缀的字段规则在 JSON 内容上按相对 JSONPath 解析
      final viaEngine =
          RuleEngine.extractTextList(json, 'data[*].name');
      expect(viaEngine, ['书籍A', '书籍B']);
      final single = RuleEngine.extractText(json, 'data[0].name');
      expect(single, '书籍A');
      final list = RuleEngine.extractElements(json, 'data[*]');
      expect(list, isNotEmpty);
    });

    test('中文 key 支持', () {
      final r = JsonPathEngine.queryString('{"书名": "测试"}', r'$.书名');
      expect(r, ['测试']);
    });

    test('非法路径不崩溃返回空', () {
      expect(JsonPathEngine.queryString(json, r'$..['), isEmpty);
      expect(JsonPathEngine.queryString('不是json', r'$.data'), isEmpty);
    });
  });

  group('RuleEngine JSONPath 集成', () {
    const json = '''
    [{"name": "书1", "author": "作者1", "detail": {"url": "http://x/1"}},
     {"name": "书2", "author": "作者2", "detail": {"url": "http://x/2"}}]
    ''';

    test('extractText 取第一条', () {
      expect(RuleEngine.extractText(json, r'$[*].name'), '书1');
    });

    test('extractTextList 取全部', () {
      expect(RuleEngine.extractTextList(json, r'$[*].name'), ['书1', '书2']);
    });

    test('extractElements + getElementText 列表循环模式', () {
      final items = RuleEngine.extractElements(json, r'$[*]');
      expect(items.length, 2);
      final name = RuleEngine.getElementText(items[0], r'$.name');
      expect(name, '书1');
      final nested = RuleEngine.getElementText(items[0], r'$.detail.url');
      expect(nested, 'http://x/1');
    });

    test('数字值转字符串', () {
      expect(RuleEngine.extractText('[{"count": 42}]', r'$[0].count'), '42');
    });

    test('CSS 规则不回归（分流正确）', () {
      const html = '<div class="item"><h3>标题</h3></div>';
      expect(RuleEngine.extractText(html, 'h3'), '标题');
      expect(RuleEngine.extractElements(html, 'div.item'), hasLength(1));
    });
  });
}
