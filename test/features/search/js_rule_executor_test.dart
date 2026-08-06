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
}
