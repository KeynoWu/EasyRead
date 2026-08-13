import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/usecases/run_single_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const html = '<div class="book"><h3>书名A</h3></div>'
      '<div class="book"><h3>书名B</h3></div>';

  const usecase = RunSingleRule();

  group('RunSingleRule 各类型执行', () {
    test('CSS 提取多值（属性）', () async {
      final r = await usecase.run(
        sample: html,
        rule: 'div.book@text',
        type: RuleTesterType.css,
      );
      expect(r.error, isNull);
      expect(r.count, 2);
      expect(r.values, ['书名A', '书名B']);
    });

    test('CSS 提取多值（级联选择器）', () async {
      final r = await usecase.run(
        sample: html,
        rule: 'class.book.0@tag.h3@text',
        type: RuleTesterType.css,
      );
      expect(r.error, isNull);
      expect(r.values, ['书名A']);
    });

    test('XPath 提取文本', () async {
      final r = await usecase.run(
        sample: html,
        rule: '//h3',
        type: RuleTesterType.css,
      );
      expect(r.error, isNull);
      expect(r.values, ['书名A', '书名B']);
    });

    test('AllInOne 正则链返回捕获组', () async {
      final r = await usecase.run(
        sample: html,
        rule: ':class="book".*?<h3>(.*?)</h3>',
        type: RuleTesterType.css,
      );
      expect(r.error, isNull);
      expect(r.count, greaterThanOrEqualTo(2));
      expect(r.values.first, contains('书名A'));
    });

    test('JSONPath 过滤结果', () async {
      const json = '{"books":[{"name":"A","price":10},{"name":"B","price":20}]}';
      final r = await usecase.run(
        sample: json,
        rule: r'$.books[?(@.price>15)].name',
        type: RuleTesterType.jsonPath,
      );
      expect(r.error, isNull);
      expect(r.values, ['B']);
    });

    test('JSONPath 数组展开字符串化', () async {
      final r = await usecase.run(
        sample: '[1,2,3]',
        rule: r'$[*]',
        type: RuleTesterType.jsonPath,
      );
      expect(r.error, isNull);
      expect(r.values, ['1', '2', '3']);
    });

    test('URL 模板展开（JSON 上下文）', () async {
      final r = await usecase.run(
        sample: '{"q":"三体"}',
        rule: r'https://x.com/search?q={{$.q}}',
        type: RuleTesterType.template,
      );
      expect(r.error, isNull);
      expect(r.values, ['https://x.com/search?q=三体']);
    });

    test('URL 模板相对路径基于 baseUrl 展开', () async {
      final r = await usecase.run(
        sample: '{"path":"/book/1.html"}',
        rule: r'{{$.path}}',
        type: RuleTesterType.template,
        baseUrl: 'https://x.com',
      );
      expect(r.error, isNull);
      expect(r.values, ['https://x.com/book/1.html']);
    });

    test('URL 模板无 baseUrl 相对路径给出提示', () async {
      final r = await usecase.run(
        sample: '{"path":"/book/1.html"}',
        rule: r'{{$.path}}',
        type: RuleTesterType.template,
      );
      expect(r.error, isNull);
      expect(r.values, ['/book/1.html']);
      expect(r.note, contains('baseUrl'));
    });

    test('JS 规则执行或降级说明', () async {
      final r = await usecase.run(
        sample: html,
        rule: "@js:java.get('tag.h3@text')",
        type: RuleTesterType.js,
      );
      if (r.error?.kind == RuleTesterErrorKind.unsupported) {
        // 无引擎平台（iOS）：降级说明
        expect(r.error!.message, contains('引擎'));
        expect(r.note, contains('降级'));
      } else {
        expect(r.error, isNull);
        expect(r.values, ['书名A']);
      }
    });
  });

  group('RunSingleRule 错误分类（不抛未捕获异常）', () {
    test('坏 JSON → 样本解析失败', () async {
      final r = await usecase.run(
        sample: '{not json',
        rule: r'$.a',
        type: RuleTesterType.jsonPath,
      );
      expect(r.error, isNotNull);
      expect(r.error!.kind, RuleTesterErrorKind.sampleParse);
      expect(r.error!.message, contains('JSON'));
      expect(r.count, 0);
    });

    test('坏 HTML（NUL 字节）→ 样本解析失败', () async {
      final r = await usecase.run(
        sample: '\u0000\u0000',
        rule: 'div.book',
        type: RuleTesterType.css,
      );
      expect(r.error, isNotNull);
      expect(r.error!.kind, RuleTesterErrorKind.sampleParse);
    });

    test('空样本 → 样本解析失败', () async {
      final r = await usecase.run(
        sample: '',
        rule: 'div.book',
        type: RuleTesterType.css,
      );
      expect(r.error, isNotNull);
      expect(r.error!.kind, RuleTesterErrorKind.sampleParse);
    });

    test('坏正则（AllInOne）→ 规则语法错误', () async {
      final r = await usecase.run(
        sample: html,
        rule: ':([unclosed&&x',
        type: RuleTesterType.css,
      );
      expect(r.error, isNotNull);
      expect(r.error!.kind, RuleTesterErrorKind.ruleSyntax);
      expect(r.error!.message, contains('正则'));
    });

    test('坏正则（## 替换后缀）→ 规则语法错误', () async {
      final r = await usecase.run(
        sample: html,
        rule: 'div.book@text##[unclosed##',
        type: RuleTesterType.css,
      );
      expect(r.error, isNotNull);
      expect(r.error!.kind, RuleTesterErrorKind.ruleSyntax);
    });

    test('空规则 → 规则语法错误', () async {
      final r = await usecase.run(
        sample: html,
        rule: '',
        type: RuleTesterType.css,
      );
      expect(r.error, isNotNull);
      expect(r.error!.kind, RuleTesterErrorKind.ruleSyntax);
    });

    test('模板样本坏 JSON → 样本解析失败', () async {
      final r = await usecase.run(
        sample: '{bad',
        rule: r'https://x.com?q={{$.q}}',
        type: RuleTesterType.template,
      );
      expect(r.error, isNotNull);
      expect(r.error!.kind, RuleTesterErrorKind.sampleParse);
    });

    test('耗时与结果字段齐全', () async {
      final r = await usecase.run(
        sample: html,
        rule: 'div.book@text',
        type: RuleTesterType.css,
      );
      expect(r.elapsed, isNotNull);
      expect(r.isSuccess, isTrue);
    });
  });

  group('RunSingleRule 书源上下文', () {
    test('书源提供 baseUrl 供模板相对路径展开', () async {
      const source = BookSource(
        id: 's1',
        name: '测试源',
        bookSourceUrl: 'https://x.com',
        rules: {'charset': 'utf-8'},
      );
      final r = await usecase.run(
        sample: '{"path":"/a.html"}',
        rule: r'{{$.path}}',
        type: RuleTesterType.template,
        source: source,
      );
      expect(r.error, isNull);
      expect(r.values, ['https://x.com/a.html']);
    });
  });
}
