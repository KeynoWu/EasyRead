import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/search/data/engines/rule_template.dart';

void main() {
  group('BookSource.concurrentRate 兼容性(审查修复)', () {
    BookSource source(Map<String, dynamic> rules) => BookSource(
          id: 't',
          name: '测试源',
          rules: rules,
        );

    test('JSON 数字型转字符串', () {
      expect(source({'concurrentRate': 1000}).concurrentRate, '1000');
      expect(source({'concurrentRate': 20.0}).concurrentRate, '20');
    });

    test('空白串视同未配置', () {
      expect(source({'concurrentRate': '  '}).concurrentRate, isNull);
      expect(source({'concurrentRate': ''}).concurrentRate, isNull);
    });

    test('0/0.0 视为不限制', () {
      expect(source({'concurrentRate': 0}).concurrentRate, isNull);
      expect(source({'concurrentRate': '0'}).concurrentRate, isNull);
    });

    test('N/M 与单数字正常透传', () {
      expect(source({'concurrentRate': '6/1000'}).concurrentRate, '6/1000');
      expect(source({'concurrentRate': '500'}).concurrentRate, '500');
    });

    test('未配置返回 null(回退全局默认限流)', () {
      expect(source({}).concurrentRate, isNull);
    });
  });

  group('RuleTemplate <page,N> 占位符(审查修复)', () {
    test('page=null 保留占位符（Legado AnalyzeUrl page?.let 语义）', () {
      final out = RuleTemplate.interpolate(
        'https://a.com/list/<1,50,100>.html',
      );
      // 与 Legado 一致：page 未提供时 <page,N> 占位符原样保留，
      // 待真实翻页传入 page 后再解析
      expect(out, 'https://a.com/list/<1,50,100>.html');
      expect(out.contains('<'), isTrue);
    });

    test('page 已知时行为不变:取第 page 段', () {
      expect(
        RuleTemplate.interpolate(
          'https://a.com/<10,20,30>.html',
          page: 2,
        ),
        'https://a.com/20.html',
      );
    });

    test('page 越界取最后一段', () {
      expect(
        RuleTemplate.interpolate(
          'https://a.com/<10,20>.html',
          page: 5,
        ),
        'https://a.com/20.html',
      );
    });

    test('非占位符尖括号文本不受影响', () {
      // 无逗号的 <xxx> 会被当作单段占位符取整段——与修复前行为一致
      expect(
        RuleTemplate.interpolate('https://a.com/<abc>.html', page: 1),
        'https://a.com/abc.html',
      );
    });
  });
}
