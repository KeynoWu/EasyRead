import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';

void main() {
  const html = '<div class="item"><h3>书名A</h3></div>';

  tearDown(() {
    JsRuleExecutor.fetcher = null;
  });

  test('setContent(result) 后查询新文档', () async {
    const rule =
        "<js>java.setContent(result); java.get('h3')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '书名A');
  });

  test('setContent 前/后 get 分别查对应文档', () async {
    const rule = "<js>a = java.get('h3'); java.setContent('<p>新内容</p>'); "
        "b = java.get('p'); a + '/' + b</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '书名A/新内容');
  });

  test('ajax + setContent + get 核心组合（setContent 参数依赖 ajax 结果）',
      () async {
    JsRuleExecutor.fetcher = (url) async {
      expect(url, 'https://api.example.com/detail');
      return '<div><span class="title">接口标题</span></div>';
    };
    const rule = "<js>c = java.ajax('https://api.example.com/detail'); "
        "java.setContent(c); java.get('span.title')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '接口标题');
  });

  test('ajax + setContent 组合：重录不重复请求', () async {
    var calls = 0;
    JsRuleExecutor.fetcher = (url) async {
      calls++;
      return '<b>重复检查</b>';
    };
    const rule = "<js>c = java.ajax('https://api.example.com/x'); "
        "java.setContent(c); java.get('b')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '重复检查');
    // 第一遍收集 URL 请求一次；重录走 __ajaxCache 不再请求
    expect(calls, 1);
  });

  test('get 动态选择器（变量参数）在 setContent 后查询', () async {
    const rule = "<js>s = 'h3'; java.setContent(result); java.get(s)</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '书名A');
  });

  test("java.get('url') 特判与 setContent 混合序号不错位", () async {
    JsRuleExecutor.fetcher = (url) async => '<i>真实</i>';
    const rule = "<js>u = java.get('url'); c = java.ajax(u); "
        "java.setContent(c); java.get('i')</js>";
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://source.example.com/page',
    );
    expect(v, '真实');
  });

  test('setContent 规则中 get 查询无结果返回空串', () async {
    const rule = "<js>java.setContent('<div>无匹配</div>'); "
        "java.get('span.missing')</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, isNull);
  });
}
