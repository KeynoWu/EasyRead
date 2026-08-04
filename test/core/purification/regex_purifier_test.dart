import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';

void main() {
  test('should replace full-width punctuation', () {
    const input = '这是，一个。测试「文章」';
    final rules = [
      PurifyRule(pattern: '，', replacement: ','),
      PurifyRule(pattern: '。', replacement: '.'),
    ];
    final purifier = RegexPurifier(rules: rules);
    final result = purifier.purify(input);
    expect(result, equals('这是,一个.测试「文章」'));
  });

  test('should remove extra blank lines', () {
    const input = '第一行\n\n\n\n\n第二行';
    final purifier = RegexPurifier(rules: [
      PurifyRule(pattern: r'\n{3,}', replacement: '\n\n'),
    ]);
    final result = purifier.purify(input);
    expect(result, equals('第一行\n\n第二行'));
  });
}
