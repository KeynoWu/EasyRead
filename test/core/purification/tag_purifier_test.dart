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

  test('should not strip legitimate content whose class contains "ad" substring', () {
    const input = '''
      <div class="header">页头</div>
      <div class="read-content">正文内容</div>
      <div class="shadow">阴影装饰</div>
      <p class="heading">章节标题</p>
    ''';
    final result = purifier.purify(input);
    expect(result, contains('页头'));
    expect(result, contains('正文内容'));
    expect(result, contains('阴影装饰'));
    expect(result, contains('章节标题'));
  });

  test('should strip ad variants with token boundaries', () {
    const input = '''
      <div class="ad">广告1</div>
      <div class="ads">广告2</div>
      <div class="ad-container">广告3</div>
      <div class="banner-ad">广告4</div>
      <div class="content ad-wrap">广告5</div>
      <div id="advertisement-box">广告6</div>
    ''';
    final result = purifier.purify(input);
    for (var i = 1; i <= 6; i++) {
      expect(result, isNot(contains('广告$i')));
    }
  });
}
