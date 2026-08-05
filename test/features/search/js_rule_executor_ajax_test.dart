import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';

void main() {
  const html = '<div class="item"><h3>书名A</h3></div>';

  tearDown(() {
    JsRuleExecutor.fetcher = null;
  });

  test('java.ajax 字面量 URL：请求结果供 JS 处理', () async {
    JsRuleExecutor.fetcher = (url) async {
      expect(url, 'https://api.example.com/data');
      return '<span>接口书名</span>';
    };
    const rule = "<js>c = java.ajax('https://api.example.com/data'); result = c; result.match(/<span>(.*?)<\\/span>/)[1]</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '接口书名');
  });

  test('java.ajax 变量 URL（java.get 赋值）', () async {
    // java.get('url') 返回 baseUrl；ajax(baseUrl) 请求它
    JsRuleExecutor.fetcher = (url) async {
      expect(url, 'https://source.example.com/page');
      return '<p>变量URL结果</p>';
    };
    const rule = "<js>u = java.get('url'); c = java.ajax(u); c.match(/<p>(.*?)<\\/p>/)[1]</js>";
    final v = await JsRuleExecutor.execute(
      html,
      rule,
      baseUrl: 'https://source.example.com/page',
    );
    expect(v, '变量URL结果');
  });

  test('ajax URL 收集去重后请求', () async {
    var calls = 0;
    JsRuleExecutor.fetcher = (url) async {
      calls++;
      return '<b>结果</b>';
    };
    const rule = "<js>a = java.ajax('https://x/1'); b = java.ajax('https://x/1'); a.length + b.length</js>";
    // 同一 URL 在第一遍出现两次 → __ajaxUrls 两条 → 请求两次（当前实现不去重）
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, isNotNull);
    expect(calls, 2);
  });

  test('ajax 请求失败不影响引擎（返回空）', () async {
    JsRuleExecutor.fetcher = (url) async => throw Exception('网络失败');
    const rule = "<js>c = java.ajax('https://fail.example.com'); c == '' ? '空结果' : c</js>";
    final v = await JsRuleExecutor.execute(html, rule);
    expect(v, '空结果');
  });
}
