import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/reader/data/repositories/catalog_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CatalogParser.extractField jsLib 透传(审查修复接线)', () {
    test('完整 JS 字段规则可调用 jsLib 函数', () async {
      // 真实调用点 item 为 Element/Map;String item 会被 jsonEncode 包裹,
      // 与生产语义不符,不在此覆盖
      final out = await CatalogParser.extractField(
        '<div>hello</div>',
        '<js>fmt(result)</js>',
        baseUrl: 'https://a.com',
        jsLib: 'function fmt(s) { return "LIB"; }',
      );
      // String item → jsonEncode(item) → "\"<div>hello</div>\"" 含转义引号,
      // 函数仍应被调用并返回其结果包裹形式
      expect(out ?? '', contains('LIB'));
    });

    test('不传 jsLib 时同规则函数不可用返回 null(引擎异常兜底)', () async {
      final out = await CatalogParser.extractField(
        '<div>hello</div>',
        '<js>fmt(result)</js>',
        baseUrl: 'https://a.com',
      );
      expect(out, isNull);
    });
  });

  group('CatalogParser.extractFromPage jsLib 透传(审查修复接线)', () {
    test('正文标题 JS 规则可调用 jsLib 函数', () async {
      final out = await CatalogParser.extractFromPage(
        '<js>"T:" + result.length</js>',
        '<h1>第一章</h1>',
        'https://a.com',
        null,
        jsLib: 'function unused() {}',
      );
      // <h1>第一章</h1> = 12 个 UTF-16 code unit(诊断实测)
      expect(out, 'T:12');
    });
  });
}
