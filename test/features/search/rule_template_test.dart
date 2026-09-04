import 'package:easy_read/features/search/data/engines/rule_template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RuleTemplate 支持 JSON 字段插值', () {
    const template = r'/detail?book_id={{$.book_id}}&source={{$.source}}';
    final url = RuleTemplate.interpolate(
      template,
      json: const {'book_id': '123', 'source': '番茄'},
      encodeValues: true,
    );
    expect(url, '/detail?book_id=123&source=%E7%95%AA%E8%8C%84');
  });

  test('RuleTemplate 支持默认值兜底', () {
    final value = RuleTemplate.interpolate(
      r'{{$.time || 未知}}',
      json: const <String, dynamic>{},
    );
    expect(value, '未知');
  });

  test('RuleTemplate 支持 key/page 变量', () {
    expect(
      RuleTemplate.interpolate(
        '/search?q={{key}}&page={{page}}',
        values: const {'key': '测试'},
        page: 2,
      ),
      '/search?q=测试&page=2',
    );
  });

  test('RuleTemplate 支持 {{@@...}} 内嵌 HTML 规则', () {
    const html = '''
      <div>
        <span>类别：玄幻</span>
        <span>更新时间：2026</span>
      </div>
    ''';
    expect(
      RuleTemplate.interpolate(
        '/detail?type={{@@span:contains(类别：)@text##类别：}}',
        html: html,
      ),
      '/detail?type=玄幻',
    );
  });

  test('RuleTemplate 支持 page 四则运算模板', () {
    expect(
      RuleTemplate.interpolate(
        '/list?passback={{(page-1)*50}}&p={{page+1}}',
        page: 2,
      ),
      '/list?passback=50&p=3',
    );
    expect(
      RuleTemplate.interpolate(
        '/list?offset={{(page-1)*20+1}}',
        page: 3,
      ),
      '/list?offset=41',
    );
  });

  test('RuleTemplate 支持 <page1,page2> 翻页占位符（Legado 语义）', () {
    // page 从 1 起：取第 page 段
    expect(
      RuleTemplate.interpolate('/a<10,20,30>.html', page: 1),
      '/a10.html',
    );
    expect(
      RuleTemplate.interpolate('/a<10,20,30>.html', page: 3),
      '/a30.html',
    );
    // 越界取最后一段
    expect(
      RuleTemplate.interpolate('/a<10,20,30>.html', page: 9),
      '/a30.html',
    );
  });

  test('page 缺省占位符原样保留（Legado AnalyzeUrl page?.let 语义）', () {
    // 旧「审查修复」按第 1 页取段系对 Legado 的误读：
    // AnalyzeUrl.kt:192 page?.let —— page 为 null 时不替换，占位符保留，
    // 待真实翻页请求传入 page 后再解析
    expect(RuleTemplate.interpolate('/a<10,20>.html'), '/a<10,20>.html');
  });
}
