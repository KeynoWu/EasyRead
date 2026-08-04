import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/purification/tag_purifier.dart';

void main() {
  late TagPurifier purifier;

  setUp(() {
    purifier = TagPurifier();
  });

  test('should remove script tags', () {
    const input = '<p>正文</p><script>alert("广告")</script><p>继续</p>';
    final result = purifier.purify(input);
    expect(result, contains('正文'));
    expect(result, contains('继续'));
    expect(result, isNot(contains('alert')));
  });

  test('should remove style tags', () {
    const input = '<p>内容</p><style>.ad{display:none}</style>';
    final result = purifier.purify(input);
    expect(result, isNot(contains('display:none')));
  });

  test('should remove ad container by common selectors', () {
    const input = '<div class="ad">广告</div><p>正文</p><div id="footer">尾</div>';
    final result = purifier.purify(input);
    expect(result, isNot(contains('广告')));
    expect(result, contains('正文'));
  });
}
