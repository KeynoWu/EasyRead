import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const html = '<div>占位</div>';
  group('jsLib 共享作用域（Legado jsLib 语义）', () {
    test('脚本字符串注入后规则内可调用', () async {
      final result = await JsRuleExecutor.execute(
        '<div>占位</div>',
        '<js>format(result)</js>',
        jsLib: 'function format(s) { return "lib:" + s; }',
      );
      expect(result, 'lib:<div>占位</div>');
    });

    test('JSON 形式 {名称: 脚本} 注入', () async {
      final result = await JsRuleExecutor.execute(
        '<div>x</div>',
        '<js>LIB_VERSION</js>',
        jsLib: '{"ver": "const LIB_VERSION = 42;"}',
      );
      expect(result, '42');
    });

    test('jsLib 语法错误整次 eval 失败返回 null（与 Legado 一致）', () async {
      // lib 与规则体同一次 eval：lib 的 throw/语法错误会使该次 eval
      // 失败（Legado SharedJsScope 同语义），执行器兜底返回 null。
      final result = await JsRuleExecutor.execute(
        '<div>y</div>',
        '<js>"ok"</js>',
        jsLib: 'throw new Error("broken lib");',
      );
      expect(result, isNull);
    });

    test('P1-8 jsLib 顶层 const 多次 eval 不重复声明（单次注入）', () async {
      // 修复前：lib 每次 eval 都拼入，全局词法环境 let/const 重复声明
      // SyntaxError → 整规则降级 null
      const rule = '<js>LIB_VERSION + 1</js>';
      final v = await JsRuleExecutor.execute(
        html,
        rule,
        jsLib: 'const LIB_VERSION = 42;',
      );
      expect(v, '43');
    });

    test('P1-8 jsLib JSON URL 条目：下载并注入（fetcher 桩）', () async {
      JsRuleExecutor.fetcher = (url) async {
        expect(url, 'https://lib.example.com/helper.js');
        return 'function helper() { return "url-lib"; }';
      };
      const rule = '<js>helper()</js>';
      final v = await JsRuleExecutor.execute(
        html,
        rule,
        jsLib: '{"helper": "https://lib.example.com/helper.js"}',
      );
      expect(v, 'url-lib');
      JsRuleExecutor.fetcher = null;
    });

    test('jsLib 缺省不注入', () async {
      final result = await JsRuleExecutor.execute('<div>z</div>', '<js>"plain"</js>');
      expect(result, 'plain');
    });
  });
}
