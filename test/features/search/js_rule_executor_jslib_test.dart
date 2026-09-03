import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

    test('jsLib 缺省不注入', () async {
      final result = await JsRuleExecutor.execute('<div>z</div>', '<js>"plain"</js>');
      expect(result, 'plain');
    });
  });
}
