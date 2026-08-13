import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/json_path.dart';

void main() {
  group('JsonPathEngine 过滤表达式 [?(...)]', () {
    const json = '''
    {
      "data": [
        {"id": 1, "name": "书籍A", "count": 10},
        {"id": 2, "name": "书籍B", "count": 20},
        {"id": 3, "name": "novel", "count": 30}
      ],
      "list": [
        {"name": "abc", "value": 1},
        {"name": "def", "value": 5},
        {"name": "a)b", "value": 9}
      ],
      "items": [
        {"count": 3, "type": "novel", "detail": {"price": 10}},
        {"count": 7, "type": "novel", "detail": {"price": 20}},
        {"count": 2, "type": "manga", "detail": {"price": 5}}
      ],
      "nums": [1, 2, 3, 4, 5],
      "empty": []
    }
    ''';

    test('数字 == 过滤', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id==1)].name'),
        ['书籍A'],
      );
    });

    test('数字 != 过滤', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id!=2)].name'),
        ['书籍A', 'novel'],
      );
    });

    test('数字 >/>=/</<= 过滤', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id>=2)].name'),
        ['书籍B', 'novel'],
      );
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id>1)].name'),
        ['书籍B', 'novel'],
      );
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id<3)].name'),
        ['书籍A', '书籍B'],
      );
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id<=2)].name'),
        ['书籍A', '书籍B'],
      );
    });

    test("字符串单引号比较 @['name']", () {
      expect(
        JsonPathEngine.queryString(json, r"$.list[?(@['name']=='abc')].value"),
        [1],
      );
    });

    test('字符串双引号字面量比较', () {
      expect(
        JsonPathEngine.queryString(json, '\$.list[?(@[\'name\']=="def")].value'),
        [5],
      );
    });

    test('&& 逻辑与', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id>0 && @.id<3)].name'),
        ['书籍A', '书籍B'],
      );
    });

    test('|| 逻辑或', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id==1 || @.id==3)].name'),
        ['书籍A', 'novel'],
      );
    });

    test('括号分组 ( )', () {
      expect(
        JsonPathEngine.queryString(
            json, r"$.items[?((@.count>5 || @.count<3) && @.type=='novel')].count"),
        [7],
      );
    });

    test('嵌套属性 @.a.b', () {
      expect(
        JsonPathEngine.queryString(json, r'$.items[?(@.detail.price>=20)].count'),
        [7],
      );
    });

    test('裸 @ 作用于元素本身', () {
      expect(JsonPathEngine.queryString(json, r'$.nums[?(@>3)]'), [4, 5]);
      expect(JsonPathEngine.queryString(json, r'$.nums[?(@==2)]'), [2]);
    });

    test('字符串字面量内含右括号 )', () {
      expect(
        JsonPathEngine.queryString(json, r'$.list[?(@.name=="a)b")].value'),
        [9],
      );
      expect(
        JsonPathEngine.queryString(json, r"$.list[?(@.name=='a)b')].value"),
        [9],
      );
    });

    test('true/false/null 字面量', () {
      const j = '''
      {"books": [
        {"name": "a", "vip": true},
        {"name": "b", "vip": false},
        {"name": "c", "vip": null}
      ]}
      ''';
      expect(JsonPathEngine.queryString(j, r'$.books[?(@.vip==true)].name'), ['a']);
      expect(
        JsonPathEngine.queryString(j, r'$.books[?(@.vip==false)].name'),
        ['b'],
      );
      expect(JsonPathEngine.queryString(j, r'$.books[?(@.vip==null)].name'), ['c']);
    });

    test('中文属性名', () {
      const j = '{"books": [{"书名": "测试", "id": 1}, {"书名": "其他", "id": 2}]}';
      expect(JsonPathEngine.queryString(j, r'$.books[?(@.id==2)].书名'), ['其他']);
    });

    test('空数组过滤返回空', () {
      expect(JsonPathEngine.queryString(json, r'$.empty[?(@.x==1)]'), isEmpty);
    });

    test('无匹配返回空', () {
      expect(JsonPathEngine.queryString(json, r'$.data[?(@.id==99)]'), isEmpty);
    });

    test('表达式语法错误跳过该步原样返回', () {
      // 语法错误：不抛异常，跳过过滤步骤，输入原样返回（整个数组）
      final result = JsonPathEngine.queryString(json, r'$.data[?(@.id==)]');
      expect(result, hasLength(1));
      expect(result.first, isA<List>());
      expect(result.first as List, hasLength(3));
      final result2 = JsonPathEngine.queryString(json, r'$.data[?(@.id > )]');
      expect(result2, hasLength(1));
      expect(result2.first as List, hasLength(3));
    });

    test('与 .. 递归下降组合', () {
      expect(
        JsonPathEngine.queryString(
            json, r"$..items[?(@.count>5 && @.type=='novel')].count"),
        [7],
      );
    });

    test('与 [N] 索引组合', () {
      const nested = '{"groups": [[{"id": 1}, {"id": 2}], [{"id": 3}]]}';
      // [N] 取内层数组后过滤其元素
      expect(
        JsonPathEngine.queryString(nested, r'$.groups[0][?(@.id==2)].id'),
        [2],
      );
    });

    test('与 [*] 展开组合', () {
      const nested = '{"groups": [[{"id": 1}, {"id": 2}], [{"id": 3}]]}';
      // [*] 展开出内层数组列表，过滤逐个作用于数组元素
      expect(
        JsonPathEngine.queryString(nested, r'$.groups[*][?(@.id==2)].id'),
        [2],
      );
    });

    test('过滤作用于数组元素：先展开后过滤无列表可过滤', () {
      // [*] 已把数组展开成元素，[?()] 只作用于 List 节点 → 无结果
      expect(
        JsonPathEngine.queryString(json, r'$.data[*][?(@.id==1)].name'),
        isEmpty,
      );
    });

    test('过滤器内部 && 不被顶层组合拆分', () {
      // 若被顶层 && 误拆，$.data[?(@.id>0 段会解析失败返回空
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id>0 && @.id<3)].name'),
        ['书籍A', '书籍B'],
      );
    });

    test('Legado && 组合与过滤器共存：前者空则用后者', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id==99)]&&$.list[0].value'),
        [1],
      );
    });

    test('Legado && 组合与过滤器共存：前者有结果则优先', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.id==1)].name&&$.list[0].value'),
        ['书籍A'],
      );
    });

    test('过滤表达式跨层组合后取字段', () {
      expect(
        JsonPathEngine.queryString(json, r'$.data[?(@.count>10)].name'),
        ['书籍B', 'novel'],
      );
    });
  });
}
