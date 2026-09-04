import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';

void main() {
  test('should replace full-width punctuation', () {
    const input = '这是，一个。测试「文章」';
    final rules = [
      const PurifyRule(pattern: '，', replacement: ','),
      const PurifyRule(pattern: '。', replacement: '.'),
    ];
    final purifier = RegexPurifier(rules: rules);
    final result = purifier.purify(input);
    expect(result, equals('这是,一个.测试「文章」'));
  });

  test('should remove extra blank lines', () {
    const input = '第一行\n\n\n\n\n第二行';
    const purifier = RegexPurifier(rules: [
      PurifyRule(pattern: r'\n{3,}', replacement: '\n\n'),
    ]);
    final result = purifier.purify(input);
    expect(result, equals('第一行\n\n第二行'));
  });

  group('replacement 捕获组展开（对齐 Legado appendReplacement，双路径一致）', () {
    test(r'$1 引用捕获组、$0/$& 引用整个匹配', () {
      const input = '第１章 起点';
      // Legado 内置净化 #09 风格：全角引号命中 → $2 重排
      const purifier = RegexPurifier(rules: [
        PurifyRule(pattern: r'第(.)章\s*(.*)', replacement: r'$1章 $2'),
      ]);
      expect(purifier.purify(input), equals('１章 起点'));
    });

    test(r'$0 与 $& 均为整个匹配', () {
      const purifier = RegexPurifier(rules: [
        PurifyRule(pattern: r'x(\d)x', replacement: r'[$0|$&|$1]'),
      ]);
      expect(purifier.purify('ax2x'), equals('a[x2x|x2x|2]'));
    });

    test(r'$$ 与 \$ 为字面 $（金额等场景）', () {
      const purifier = RegexPurifier(rules: [
        PurifyRule(pattern: '价格', replacement: r'$$0.99 / \$0.99'),
      ]);
      expect(purifier.purify('价格：五元'), equals(r'$0.99 / $0.99：五元'));
    });

    test('越界组引用为空串（Legado 抛错弃规则，此处更宽容）', () {
      const purifier = RegexPurifier(rules: [
        PurifyRule(pattern: 'ab', replacement: r'[$9][$1]'),
      ]);
      // $9 不存在 → 空；$1 不存在 → 空
      expect(purifier.purify('ab'), equals('[][]'));
    });

    test('purifyAsync 路径（isolate 内）同样展开捕获组', () async {
      const purifier = RegexPurifier(rules: [
        PurifyRule(pattern: r'(\d+)元', replacement: r'¥$1'),
      ]);
      final result = await purifier.purifyAsync('共12元');
      expect(result, equals('共¥12'));
    });

    test('literalReplacement=true 纯字面（对齐 Legado 非正则规则）', () {
      const purifier = RegexPurifier(rules: [
        PurifyRule(
          pattern: '价格',
          replacement: r'$0.99（$1）',
          literalReplacement: true,
        ),
      ]);
      // $0/$1 不展开，保持字面
      expect(purifier.purify('价格：五元'), equals(r'$0.99（$1）：五元'));
    });
  });
}
