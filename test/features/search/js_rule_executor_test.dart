import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';

void main() {
  const html = '<div class="item"><img src="http://c/1.jpg"><h3>书名A</h3></div>';

  test('纯字符串处理（正则 match）', () async {
    const rule = '<js>r = result.match(/<h3>(.*?)<\\/h3>/); r[1]</js>';
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '书名A');
  });

  test('字符串拼接与变量', () async {
    const rule = "@js:var a = '书名'; var b = 'B'; a + b";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '书名B');
  });

  test('java.get 字面量选择器注入查询', () async {
    const rule = "@js:java.get('tag.h3@text')";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '书名A');
  });

  test('java.get 字面量 + 属性提取', () async {
    const rule = "@js:java.get('tag.img', 'src')";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, 'http://c/1.jpg');
  });

  test('死循环超时后引擎可复用', () async {
    const loop = "<js>while(true){}; 'x'</js>";
    final v = await JsRuleExecutor.execute(html, loop);
    expect(v, isNull);
    // 回收后引擎可继续使用
    final v2 = await JsRuleExecutor.execute(html, "@js:'ok'");
    expect(v2, 'ok');
  });

  test('异常后引擎可复用（无原生崩溃）', () async {
    final v = await JsRuleExecutor.execute(html, '@js:undefinedVar.x');
    expect(v, isNull);
    final v2 = await JsRuleExecutor.execute(html, "@js:'recovered'");
    expect(v2, 'recovered');
  });

  test('不支持能力返回 null', () async {
    expect(await JsRuleExecutor.execute(html, "<js>eval('1');</js>"), isNull);
    expect(await JsRuleExecutor.execute(html, "<js>cookie.set('a','b');</js>"), isNull);
    expect(await JsRuleExecutor.execute(html, "<js>setTimeout(()=>{}, 0); 'x'</js>"), isNull);
    // JS 允许标识符内反斜杠u转义：0065val 即 eval，黑名单解码后必须命中。
    // 用 fromCharCode 拼出反斜杠，避免源码中的转义序列被工具链改写
    final bsu = String.fromCharCodes([92, 117]); // 反斜杠 + u
    expect(
      await JsRuleExecutor.execute(html, "<js>${bsu}0065val('1')</js>"),
      isNull,
    );
  });

  test('正常执行后 engine 释放（无泄漏）', () async {
    await JsRuleExecutor.execute(html, "@js:java.get('tag.h3@text')");
    // finally 中 dispose 已完成
    expect(JsRuleExecutor.liveEngineCount, 0);
    await JsRuleExecutor.execute(html, '@js:1+1');
    await JsRuleExecutor.execute(html, "<js>java.get('tag.img', 'src')</js>");
    // 多次执行不累积
    expect(JsRuleExecutor.liveEngineCount, 0);
  });

  test('并发执行共享 manager 且各自释放', () async {
    final results = await Future.wait([
      JsRuleExecutor.execute(html, "@js:java.get('tag.h3@text')"),
      JsRuleExecutor.execute(html, '@js:1+2'),
      JsRuleExecutor.execute(html, "<js>java.get('tag.img', 'src')</js>"),
    ]);
    expect(results, ['书名A', '3', 'http://c/1.jpg']);
    expect(JsRuleExecutor.liveEngineCount, 0);
  });

  test('java.put 变量在执行后回传给调用方', () async {
    const rule = "<js>java.put('book', '123'); 'ok'</js>";
    final variables = <String, String>{};
    final value = await JsRuleExecutor.execute(
      html,
      rule,
      variables: variables,
    );
    expect(value, 'ok');
    expect(variables, {'book': '123'});
  });

  test('完整 JS 规则支持常用 java 加密桥', () async {
    const rule = "@js:java.md5Encode('abc') + ':' + "
        "java.base64Encode('hello') + ':' + "
        "java.base64Decode('aGVsbG8=') + ':' + "
        "java.md5Encode16('abc')";
    final value = await JsRuleExecutor.execute(html, rule);
    expect(
      value,
      '900150983cd24fb0d6963f7d28e17f72:'
      'aGVsbG8=:hello:900150983cd24fb0',
    );
  });

  test('完整 JS 规则支持 AES/HMac/time/randomUUID', () async {
    const rule = '''
@js:java.aesBase64DecodeToString(
'EMlWA737aO7c0Mi7LKZajg==',
'0123456789abcdef',
'AES/CBC/PKCS5Padding',
'1234567890abcdef') + ':' +
java.HMacHex('data', 'HmacSHA256', 'key') + ':' +
java.timeFormatUTC(1700000000000, 'yyyy-MM-dd', 8) + ':' +
java.randomUUID()''';
    final value = await JsRuleExecutor.execute(html, rule);
    expect(value, isNotNull);
    final parts = value!.split(':');
    expect(parts, hasLength(4));
    expect(parts[0], 'hello world');
    expect(
      parts[1],
      '5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0',
    );
    expect(parts[2], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(RegExp(r'^[0-9a-f-]{36}$').hasMatch(parts[3]), isTrue);
  });

  test('完整 JS 规则 getString 读取 put 变量', () async {
    const rule = "@js:java.put('token', 'abc'); java.getString('token')";
    final value = await JsRuleExecutor.execute(html, rule);
    expect(value, 'abc');
  });

  test('完整 JS 规则支持 createSymmetricCrypto AES/3DES', () async {
    const rule = '''
@js:var aes = java.createSymmetricCrypto(
'AES/CBC/PKCS5Padding', '0123456789abcdef', '1234567890abcdef');
aes.decryptStr('EMlWA737aO7c0Mi7LKZajg==') + ':' +
aes.encryptBase64('hello world') + ':' +
aes.encryptHex('hello world') + ':' +
aes.decrypt('EMlWA737aO7c0Mi7LKZajg==').join('-') + ':' +
java.createSymmetricCrypto(
'DESede/CBC/PKCS5Padding', '0123456789abcdef01234567', '1234567890abcdef')
.decryptStr('kKqlous6dJBeu9i8g1UWTw==') + ':' +
java.createSymmetricCrypto(
'DESede/CBC/PKCS5Padding', '0123456789abcdef01234567', '1234567890abcdef')
.encryptBase64('hello world')''';
    final value = await JsRuleExecutor.execute(html, rule);
    expect(
      value,
      'hello world:'
      'EMlWA737aO7c0Mi7LKZajg==:'
      '10c95603bdfb68eedcd0c8bb2ca65a8e:'
      '104-101-108-108-111-32-119-111-114-108-100:'
      'hello world:'
      'kKqlous6dJBeu9i8g1UWTw==',
    );
  });

  test('完整 JS 规则支持 cookie 读写与 replaceCookie', () async {
    const rule = "@js:cookie.setCookie(source.getKey(), 'sotime=1; token=abc'); "
        "cookie.replaceCookie(source.getKey(), 'sotime')";
    final cookies = <String, String>{};
    final value = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://example.com/',
      cookies: cookies,
    );
    expect(value, 'token=abc');
    expect(cookies['https://example.com/'], 'token=abc');
  });

  test('完整 JS 规则支持 cookie.removeCookie 并回传', () async {
    const rule = '''
@js:var c = cookie.getCookie(source.getKey());
cookie.removeCookie(source.getKey()); c''';
    final cookies = <String, String>{'https://example.com/': 'a=1'};
    final value = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://example.com/',
      cookies: cookies,
    );
    expect(value, 'a=1');
    expect(cookies.containsKey('https://example.com/'), isFalse);
  });

  test('完整 JS 规则支持 java.getElements 集合与元素方法', () async {
    const listHtml =
        '<ul><li data-id="1">a</li><li data-id="2">b</li></ul>';
    const rule = "@js:var els = java.getElements('li'); "
        "els.length + ':' + els.attr('data-id') + ':' + "
        "els.toArray().sort((x,y)=>parseInt(y.attr('data-id'))-"
        "parseInt(x.attr('data-id')))[0].text()";
    final value = await JsRuleExecutor.execute(listHtml, rule);
    expect(value, '2:1:b');
  });

  test('完整 JS 规则 java.getElements.get 可取指定元素', () async {
    const listHtml = '<ul><li>a</li><li>b</li></ul>';
    final value = await JsRuleExecutor.execute(
      listHtml,
      "@js:java.getElements('li').get(1).text()",
    );
    expect(value, 'b');
  });

  test('完整 JS 规则 java.getElements.first/last 可取首尾元素', () async {
    const listHtml = '<ul><li>a</li><li>b</li></ul>';
    final value = await JsRuleExecutor.execute(
      listHtml,
      "@js:java.getElements('li').first().text() + ':' + "
      "java.getElements('li').last().text()",
    );
    expect(value, 'a:b');
  });

  test('setContent 后 getElements 在新文档查询', () async {
    const oldHtml = '<div class="old"><li>旧章节</li></div>';
    const rule = '''
@js:java.setContent('<div class="new"><li>新章节一</li><li>新章节二</li></div>');
java.getElements('li').length + ':' + java.getElements('li').get(1).text()''';
    final value = await JsRuleExecutor.execute(oldHtml, rule);
    expect(value, '2:新章节二');
  });

  test('完整 JS 规则 java.getString 支持 JSONPath 与 HTML 规则', () async {
    const jsonHtml = '{"data":{"book_id":123,"title":"测试书"}}';
    final jsonValue = await JsRuleExecutor.execute(
      jsonHtml,
      "@js:java.getString('\$.data.title') + ':' + java.getString('\$.data.book_id')",
    );
    expect(jsonValue, '测试书:123');

    final htmlValue = await JsRuleExecutor.execute(
      '<div class="item"><h3>书名</h3></div>',
      "@js:java.getString('tag.h3@text')",
    );
    expect(htmlValue, '书名');
  });

  test('完整 JS 规则支持 digestHex 与 java.getCookie', () async {
    final digest = await JsRuleExecutor.execute(
      html,
      "@js:java.digestHex('abc', 'MD5')",
    );
    expect(digest, '900150983cd24fb0d6963f7d28e17f72');

    final cookies = <String, String>{
      'https://example.com/': 'sid=abc123; token=xyz',
    };
    final cookieValue = await JsRuleExecutor.execute(
      html,
      "@js:java.getCookie('https://example.com/', 'sid')",
      cookies: cookies,
    );
    expect(cookieValue, 'abc123');
  });

  test('完整 JS 规则支持 java.getStringList 多值提取', () async {
    const listHtml = '<ul><li>第一章</li><li>第二章</li></ul>';
    final value = await JsRuleExecutor.execute(
      listHtml,
      "@js:java.getStringList('li@text').join('-')",
    );
    expect(value, '第一章-第二章');
  });

  test('完整 JS 规则支持 java.toNumChapter 中文数字转换', () async {
    const rule = '''
@js:java.toNumChapter('第一百二十章 风云再起') + '|' +
java.toNumChapter('第1章 开始')''';
    final value = await JsRuleExecutor.execute(html, rule);
    expect(value, '第120章 风云再起|第1章 开始');
  });

  test('完整 JS 规则支持 java.htmlFormat 基础清理', () async {
    final value = await JsRuleExecutor.execute(
      html,
      "@js:java.htmlFormat('<p>a &amp; b</p><script>bad()</script>')",
    );
    expect(value, 'a & b');
  });
}
