import 'package:easy_read/features/search/data/engines/rule_variables.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuleVariables @put/@get', () {
    test('@put 从 JSON 条目收集变量并剥离后缀', () {
      const item = {'id': '123', 'name': '书A'};
      final variables = <String, String>{};
      final rule = RuleVariables.collectAndStrip(
        r'$.name@put:{book:$.id}',
        item,
        variables,
      );
      expect(rule, r'$.name');
      expect(variables, {'book': '123'});
    });

    test('多个 @put 与冒号键值解析', () {
      const item = {'book_id': '7', 'chapter_id': '9'};
      final variables = <String, String>{};
      RuleVariables.collectAndStrip(
        r'$.book_id@put:{bid:$.book_id;cid:$.chapter_id}',
        item,
        variables,
      );
      expect(variables, {'bid': '7', 'cid': '9'});
    });

    test('@get 展开变量，未命中为空', () {
      expect(
        RuleVariables.expand(
          'https://x/book?id=@get:{bid}&tab=@get:{missing}',
          {'bid': '123'},
        ),
        'https://x/book?id=123&tab=',
      );
    });

    test('@put 值规则可引用相对 JSONPath', () {
      const item = {'result': {'book_id': '9'}};
      final variables = <String, String>{};
      RuleVariables.collectAndStrip(
        r'$.result.name@put:{book:$.result.book_id}',
        item,
        variables,
      );
      expect(variables, {'book': '9'});
    });
  });
}
