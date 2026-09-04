import 'package:easy_read/features/search/data/engines/url_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlSpec.splitOptions', () {
    test('切出 URL 与选项', () {
      final split = UrlSpec.splitOptions('https://example.com/s,{"a":1}');
      expect(split, isNotNull);
      expect(split!.url, 'https://example.com/s');
      expect(split.params['a'], 1);
    });

    test('无选项返回 null', () {
      expect(UrlSpec.splitOptions('https://example.com/s'), isNull);
    });

    test('URL 部分为空返回 null', () {
      expect(UrlSpec.splitOptions(',{"a":1}'), isNull);
    });
  });

  group('UrlSpec.containsJs', () {
    test('识别 @js: 与 <js> 段（大小写不敏感）', () {
      expect(UrlSpec.containsJs('@js:1'), isTrue);
      expect(UrlSpec.containsJs('@JS:1'), isTrue);
      expect(UrlSpec.containsJs('a<js>b</js>c'), isTrue);
      expect(UrlSpec.containsJs('https://example.com/x'), isFalse);
    });
  });

  group('UrlSpec.parse 无选项', () {
    test('纯 URL 退化为 GET', () async {
      final spec = await UrlSpec.parse('https://example.com/search?q=1');
      expect(spec.url, 'https://example.com/search?q=1');
      expect(spec.method, 'GET');
      expect(spec.headers, isEmpty);
      expect(spec.body, isNull);
      expect(spec.retry, 0);
    });

    test('选项 JSON 解析失败退化为纯 GET URL', () async {
      final spec = await UrlSpec.parse('https://example.com/s,{"method"');
      expect(spec.url, 'https://example.com/s,{"method"');
      expect(spec.method, 'GET');
    });
  });

  group('UrlSpec.parse 选项', () {
    test('双引号 JSON：method/body/charset/type/retry', () async {
      final spec = await UrlSpec.parse(
        'https://example.com/s,{"method":"POST","body":"k=1",'
        '"charset":"gbk","type":"json","retry":3}',
      );
      expect(spec.url, 'https://example.com/s');
      expect(spec.isPost, isTrue);
      expect(spec.body, 'k=1');
      expect(spec.charset, 'gbk');
      expect(spec.type, 'json');
      expect(spec.retry, 3);
    });

    test('Legado 单引号写法容错', () async {
      final spec = await UrlSpec.parse(
        "https://example.com/s,{'method':'POST','body':'a=1'}",
      );
      expect(spec.url, 'https://example.com/s');
      expect(spec.isPost, isTrue);
      expect(spec.body, 'a=1');
    });

    test('headers 为 JSON 对象：值转字符串', () async {
      final spec = await UrlSpec.parse(
        'https://example.com/s,{"headers":{"X-A":"1","X-N":2}}',
      );
      expect(spec.headers['X-A'], '1');
      expect(spec.headers['X-N'], '2');
    });

    test('headers 为 JSON 字符串', () async {
      final spec = await UrlSpec.parse(
        '''https://example.com/s,{"headers":"{\\"X-B\\": \\"v\\"}"}''',
      );
      expect(spec.headers['X-B'], 'v');
    });

    test('retry 非数字退化 0', () async {
      final spec = await UrlSpec.parse(
        'https://example.com/s,{"retry":"abc"}',
      );
      expect(spec.retry, 0);
    });

    test('逗号两侧空白对齐 paramPattern', () async {
      final spec = await UrlSpec.parse(
        'https://example.com/s , {"method":"POST"}',
      );
      expect(spec.url, 'https://example.com/s');
      expect(spec.isPost, isTrue);
    });

    test('js 选项以已解析 URL 为 result 并覆盖 URL', () async {
      String? gotJs;
      String? gotResult;
      final spec = await UrlSpec.parse(
        'https://example.com/s,{"js":"result + \\"?x=1\\""}',
        evalJs: (js, result) async {
          gotJs = js;
          gotResult = result;
          return '$result?fromjs';
        },
      );
      expect(gotJs, 'result + "?x=1"');
      expect(gotResult, 'https://example.com/s');
      expect(spec.url, 'https://example.com/s?fromjs');
    });
  });

  group('UrlSpec.resolveJs', () {
    test('全 JS URL：eval 收到代码', () async {
      String? gotJs;
      String? gotResult;
      final out = await UrlSpec.resolveJs(
        '@js:"https://example.com/" + key',
        (js, result) async {
          gotJs = js;
          gotResult = result;
          return 'https://example.com/?k=$js';
        },
      );
      expect(gotJs, '"https://example.com/" + key');
      // 首段前无文本：result 为原串
      expect(gotResult, '@js:"https://example.com/" + key');
      expect(out, 'https://example.com/?k="https://example.com/" + key');
    });

    test('<js></js> 段：后随文本段覆盖结果（Legado 语义，无 @result 标记）',
        () async {
      final out = await UrlSpec.resolveJs(
        'https://a.com/<js>"x"</js>/p',
        (js, result) async => '[$js|$result]',
      );
      // 前缀无标记 → result=前缀；JS 覆盖；尾部 '/p' 无标记 → 覆盖为 '/p'
      expect(out, '/p');
    });

    test('尾部文本 @result 引用 JS 结果', () async {
      final out = await UrlSpec.resolveJs(
        '<js>"mid"</js>prefix-@result-suffix',
        (js, result) async => 'JS值',
      );
      expect(out, 'prefix-JS值-suffix');
    });

    test('无 JS 段原样返回', () async {
      final out = await UrlSpec.resolveJs(
        'https://example.com/plain',
        (js, result) async => throw StateError('不应求值'),
      );
      expect(out, 'https://example.com/plain');
    });
  });

  group('UrlSpec.parse 求值顺序（先 JS 后选项）', () {
    test('全 JS 生成带选项的 URL', () async {
      final spec = await UrlSpec.parse(
        '@js:"https://example.com/api,{"method":"POST","body":"a=1"}"',
        evalJs: (js, result) async =>
            'https://example.com/api,{"method":"POST","body":"a=1"}',
      );
      expect(spec.url, 'https://example.com/api');
      expect(spec.isPost, isTrue);
      expect(spec.body, 'a=1');
    });
  });
}
