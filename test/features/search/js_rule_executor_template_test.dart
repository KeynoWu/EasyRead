import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JsRuleExecutor.evalTemplate {{java.*}}', () {
    test('md5Encode 使用标准 MD5', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?token={{java.md5Encode("abc")}}',
      );
      expect(result, '/x?token=900150983cd24fb0d6963f7d28e17f72');
    });

    test('base64Encode 使用 UTF-8 标准 Base64', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?v={{java.base64Encode("hello")}}',
      );
      expect(result, '/x?v=aGVsbG8=');
    });

    test('getString 从 JSON 上下文取值并支持三目表达式', () async {
      final result = await JsRuleExecutor.evalTemplate(
        r'/x?id={{java.getString("$.id")}}'
        r'&state={{java.getString("$.ok") == "1" ? "yes" : "no"}}',
        json: const {'id': '7', 'ok': '1'},
      );
      expect(result, '/x?id=7&state=yes');
    });

    test('page 变量与多个表达式组合', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?p={{java.base64Encode("p" + page)}}'
        '&m={{java.md5Encode(String(page))}}',
        page: 2,
      );
      expect(result, '/x?p=cDI=&m=c81e728d9d4c2f636f067f89cc14862c');
    });

    test('嵌套 java 调用按真实中间值计算', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?t={{java.md5Encode(java.base64Encode("hello"))}}',
      );
      expect(result, '/x?t=0733351879b2fa9bd05c7ca3061529c0');
    });

    test('timeFormatUTC 输出指定格式', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?t={{java.timeFormatUTC(1700000000000, "yyyy-MM-dd", 8)}}',
      );
      expect(result, isNotNull);
      expect(result, matches(RegExp(r'^/x\?t=\d{4}-\d{2}-\d{2}$')));
    });

    test('hex 编解码与 encodeURI', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?a={{java.hexEncodeToString("中")}}'
        '&b={{java.hexDecodeToString("e4b8ad")}}'
        '&c={{java.encodeURI("a b")}}',
      );
      expect(result, '/x?a=e4b8ad&b=中&c=a+b');
    });

    test('java.get 模板场景从 HTML 查询', () async {
      const html = '<div><span class="title">书名</span></div>';
      final result = await JsRuleExecutor.evalTemplate(
        '/x?name={{java.get("span.title@text")}}',
        html: html,
      );
      expect(result, '/x?name=书名');
    });

    test('java.put 单表达式可执行且不破坏模板', () async {
      final result = await JsRuleExecutor.evalTemplate(
        r'/x?v={{java.put("key", "1")}}',
      );
      expect(result, '/x?v=');
    });

    test('t2s 简繁转换与 randomUUID/log', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?t={{java.t2s("繁體")}}'
        '&u={{java.randomUUID()}}'
        '&l={{java.log("skip")}}',
      );
      expect(result, startsWith('/x?t=繁体&u='));
      expect(result, contains('&l='));
      final uuid = result!.substring('/x?t=繁体&u='.length, result.indexOf('&l='));
      expect(RegExp(r'^[0-9a-f-]{36}$').hasMatch(uuid), isTrue);
    });

    test('s2t 简体转繁体', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?t={{java.s2t("简体")}}',
      );
      expect(result, '/x?t=簡體');
    });

    test('base64Decode 与 base64DecodeToByteArray', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?a={{java.base64Decode("aGVsbG8=")}}'
        '&b={{java.base64DecodeToByteArray("aGVsbG8=").join("-")}}',
      );
      expect(result, '/x?a=hello&b=104-101-108-108-111');
    });

    test('HMacHex 与 HMacBase64', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?a={{java.HMacHex("data", "HmacSHA256", "key")}}'
        '&b={{java.HMacBase64("data", "HmacSHA256", "key")}}',
      );
      expect(
        result,
        '/x?a=5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0'
        '&b=UDH+PZicbRU3oBP6bnOdojRj/a7DtwE32Cjjas4iG9A=',
      );
    });

    test('aesDecodeToString 支持 ECB hex 密文', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?d={{java.aesDecodeToString('
        '"8169bed4ef49a8874559c5b200daade7", '
        '"0123456789abcdef", '
        '"AES/ECB/PKCS5Padding", "")}}',
      );
      expect(result, '/x?d=hello world');
    });

    test('aesBase64DecodeToString 支持 CBC base64 密文', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?d={{java.aesBase64DecodeToString('
        '"EMlWA737aO7c0Mi7LKZajg==", '
        '"0123456789abcdef", '
        '"AES/CBC/PKCS5Padding", '
        '"1234567890abcdef")}}',
      );
      expect(result, '/x?d=hello world');
    });

    test('aesEncodeToBase64String 输出标准 CBC base64 密文', () async {
      final result = await JsRuleExecutor.evalTemplate(
        '/x?d={{java.aesEncodeToBase64String('
        '"hello world", '
        '"0123456789abcdef", '
        '"AES/CBC/PKCS5Padding", '
        '"1234567890abcdef")}}',
      );
      expect(result, '/x?d=EMlWA737aO7c0Mi7LKZajg==');
    });

    test('不含 java 模板原样返回', () async {
      const template = '/x?p={{page}}&key={{key}}';
      expect(await JsRuleExecutor.evalTemplate(template), template);
    });
  });
}
