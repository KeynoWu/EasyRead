import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/search/data/engines/rule_engine.dart';
void main() {
  group('RuleEngine 级联选择器（Legado 兼容）', () {
    const listHtml = '''
      <div class="newbox">
        <ul>
          <li><h3><a>第一章书</a></h3><span class="c">详情1</span></li>
          <li><h3><a>第二章书</a></h3><span class="c">详情2</span></li>
        </ul>
      </div>
    ''';

    test('class.0@tag.ul.0@tag.li 级联定位列表项', () {
      final items = RuleEngine.extractElements(listHtml, 'class.newbox.0@tag.ul.0@tag.li');
      expect(items.length, 2);
    });

    test('级联 + text 伪属性提取书名', () {
      final name = RuleEngine.extractText(listHtml, 'tag.li.0@tag.a.0@text');
      expect(name, '第一章书');
    });

    test('extractTextList 级联提取全部标题', () {
      final names = RuleEngine.extractTextList(listHtml, 'class.newbox.0@tag.li@tag.a@text');
      expect(names, ['第一章书', '第二章书']);
    });

    test('getElementText 在元素内级联查询', () {
      final items = RuleEngine.extractElements(listHtml, 'class.newbox.0@tag.ul.0@tag.li');
      expect(items.length, 2);
      final title = RuleEngine.getElementText(items[0], 'tag.h3@tag.a@text');
      expect(title, '第一章书');
    });

    test('ownText 只取自身文本（不含后代）', () {
      const html = '<p>直接文本<span>子文本</span></p>';
      expect(RuleEngine.extractText(html, 'p@ownText'), '直接文本');
      expect(RuleEngine.extractText(html, 'p@text'), '直接文本子文本');
    });

    test('attr 提取与单步 CSS 不回归', () {
      const html = '<a class="d" href="http://x.com/1">详情</a>';
      expect(RuleEngine.extractText(html, 'a.d'), '详情');
    });

    test('选择器属性值内含 @ 不崩溃', () {
      const html = '<a href="a@b.com">链接</a>';
      // @ 在属性值内不应被当作级联/属性分隔符
      expect(RuleEngine.extractText(html, 'a[href*="@"]'), '链接');
      expect(RuleEngine.extractElements(html, 'a[href*="@"]'), hasLength(1));
    });

    test('id./tag./纯CSS 前缀转换', () {
      const html = '<div id="main"><h3>标题</h3></div>';
      expect(RuleEngine.extractText(html, 'id.main@tag.h3@text'), '标题');
    });
  });


  group('审查修复回归', () {
    test('@html 返回元素内部 HTML', () {
      const html = '<div id="content"><p>第一段</p><p>第二段</p></div>';
      expect(
        RuleEngine.extractText(html, 'div#content@html'),
        '<div id="content"><p>第一段</p><p>第二段</p></div>',
      );
    });

    test('Legado || 多规则兜底', () {
      const html = '<div class="no-such-class"></div><h3 class="title">书名</h3>';
      expect(
        RuleEngine.extractText(html, 'div.no-such-class@text||h3.title@text'),
        '书名',
      );
      expect(
        RuleEngine.extractElements(html, 'div.no-such-class||h3.title'),
        hasLength(1),
      );
      expect(
        RuleEngine.extractTextList(html, 'span.no-such-class@text||h3.title@text'),
        ['书名'],
      );
    });

    test('@css: 与 @json: 前缀', () {
      const html = '<div class="item"><h3>书名</h3></div>';
      expect(RuleEngine.extractText(html, '@css:div.item'), '书名');
      const json = '{"data":[{"name":"JSON书"}]}';
      expect(RuleEngine.extractText(json, r'@json:$.data[0].name'), 'JSON书');
    });

    test('textNodes/all 伪属性', () {
      const html = '<div>a<span>子文本</span>c</div>';
      expect(RuleEngine.extractText(html, 'div@textNodes'), 'a\nc');
      expect(RuleEngine.extractText(html, 'div@all'), '<div>a<span>子文本</span>c</div>');
    });

    test('Legado && 与 %% 连接规则', () {
      const html = '''
        <div class="a"><span>a1</span><span>a2</span></div>
        <div class="b"><em>b1</em><em>b2</em></div>
      ''';
      expect(
        RuleEngine.extractTextList(
          html,
          'class.a@tag.span@text&&class.b@tag.em@text',
        ),
        ['a1', 'a2', 'b1', 'b2'],
      );
      expect(
        RuleEngine.extractTextList(
          html,
          'class.a@tag.span@text%%class.b@tag.em@text',
        ),
        ['a1', 'b1', 'a2', 'b2'],
      );
    });

    test('级联索引支持负数', () {
      const html = '<div class="list"><span>a</span><span>b</span></div>';
      expect(RuleEngine.extractText(html, 'class.list@tag.span.-1@text'), 'b');
    });

    test('Legado 多索引/排除/范围/children 索引', () {
      const html = '''
        <div class="list">
          <span>a</span><span>b</span><span>c</span><span>d</span>
        </div>
      ''';
      // 冒号分隔为范围语义（0 到 2 含端点），与 [0:2] 一致
      expect(
        RuleEngine.extractTextList(html, 'class.list@tag.span.0:2@text'),
        ['a', 'b', 'c'],
      );
      expect(
        RuleEngine.extractTextList(html, 'class.list@tag.span!1@text'),
        ['a', 'c', 'd'],
      );
      expect(
        RuleEngine.extractTextList(html, 'class.list@tag.span[0,2]@text'),
        ['a', 'c'],
      );
      expect(
        RuleEngine.extractTextList(html, 'class.list@tag.span[0:2]@text'),
        ['a', 'b', 'c'],
      );
      expect(
        RuleEngine.extractTextList(html, 'class.list@tag.span[-1:0]@text'),
        ['d', 'c', 'b', 'a'],
      );
      expect(
        RuleEngine.extractTextList(html, 'class.list@children.2@text'),
        ['c'],
      );
    });
    test('旧式索引 step=0 被拒绝（不死循环、按无匹配处理）', () {
      const html = '''
        <div class="list">
          <span>a</span><span>b</span><span>c</span><span>d</span>
        </div>
      ''';
      // 修复前：parseLegacyIndexes 不拦 step==0，expandIndexes "i += 0" 死循环
      expect(
        RuleEngine.extractTextList(html, 'class.list@tag.span.1:0:0@text'),
        isEmpty,
      );
      expect(
        RuleEngine.extractTextList(html, 'class.list@children.1:0:0@text'),
        isEmpty,
      );
    });

    test('XPath 子集：//tag、[@class]、/@attr、@XPath:', () {
      const html =
          '<div class="list"><a href="/book/1">书A</a></div>';
      expect(
        RuleEngine.extractText(html, r'//div[@class="list"]//a'),
        '书A',
      );
      expect(
        RuleEngine.extractText(html, r'@XPath://a/@href'),
        '/book/1',
      );
    });

    test('XPath 直接子代 / 与后代 // 区分', () {
      const html =
          '<div class="list"><a href="/1">A</a><span><a href="/2">B</a></span></div>';
      final direct = RuleEngine.extractElements(html, r'//div[@class="list"]/a');
      expect(direct, hasLength(1));
      expect(RuleEngine.getElementText(direct.first, '@text'), 'A');
      expect(
        RuleEngine.extractElements(html, r'//div[@class="list"]//a'),
        hasLength(2),
      );
    });

    test('XPath 属性存在、contains、and 与位置索引', () {
      const html = '''
        <div class="book-item" id="first">一</div>
        <div class="book-list" id="second">二</div>
        <div class="book-item" id="third">三</div>
      ''';
      expect(
        RuleEngine.extractElements(html, r'//div[@class]'),
        hasLength(3),
      );
      expect(
        RuleEngine.extractElements(html, r'//div[contains(@class, "book-item")]'),
        hasLength(2),
      );
      expect(
        RuleEngine.extractElements(
          html,
          r'//div[@class="book-item" and @id="third"]',
        ),
        hasLength(1),
      );
      final first = RuleEngine.extractElements(html, r'//div[1]');
      expect(first, hasLength(1));
      expect(RuleEngine.getElementText(first.first, '@text'), '一');
    });

    test('XPath 非 class/id 属性相等与绝对路径', () {
      const html =
          '<html><body><a data-id="1">A</a><a data-id="2">B</a></body></html>';
      expect(
        RuleEngine.extractElements(html, r'//a[@data-id="2"]'),
        hasLength(1),
      );
      expect(RuleEngine.extractElements(html, r'/html'), hasLength(1));
      expect(RuleEngine.extractElements(html, r'/html/body'), hasLength(1));
      expect(
        RuleEngine.extractElements(html, r'/html/body/a'),
        hasLength(2),
      );
    });

    test('XPath position()>N 排除前 N 个匹配', () {
      const html = '''
        <table><tbody>
          <tr><td>表头</td></tr>
          <tr><td>行一</td></tr>
          <tr><td>行二</td></tr>
        </tbody></table>
      ''';
      expect(
        RuleEngine.extractTextList(html, r'//tbody/tr[position()>1]'),
        ['行一', '行二'],
      );
      expect(
        RuleEngine.extractTextList(html, r'//tbody/tr[position()>=2]'),
        ['行一', '行二'],
      );
      expect(
        RuleEngine.extractTextList(html, r'//tbody/tr[position()<3]'),
        ['表头', '行一'],
      );
      expect(
        RuleEngine.extractTextList(html, r'//tbody/tr[position()<=2]'),
        ['表头', '行一'],
      );
    });

    test('JSON 值条目 + 相对路径字段规则（.name）', () {
      const json = '[{"name": "书A", "detail": {"url": "http://x/1"}}]';
      final items = RuleEngine.extractElements(json, r'$[*]');
      expect(items.length, 1);
      expect(RuleEngine.getElementText(items[0], '.name'), '书A');
      expect(RuleEngine.getElementText(items[0], 'detail.url'), 'http://x/1');
      expect(RuleEngine.getElementText(items[0], r'$.name'), '书A');
    });

    test('纯 CSS 类名以数字结尾不被误当索引', () {
      const html = '<div class="item2"><h3>标题</h3></div>';
      expect(RuleEngine.extractText(html, 'div.item2'), '标题');
      // 前缀形式索引仍生效
      expect(RuleEngine.extractText(html, 'class.item2'), '标题');
      const listHtml = '<div class="box"><span>a</span><span>b</span></div>';
      expect(RuleEngine.extractText(listHtml, 'tag.span.1@text'), 'b');
    });
  });

  group('Legado AllInOne 正则与捕获组（书源兼容）', () {
    const html = '''
      <div>
        <a href="/book/1">书A</a>
        <a href="/book/2">书B</a>
      </div>
    ''';

    test(':正则 列表规则生成捕获组条目', () {
      final items = RuleEngine.extractElements(
        html,
        r':<a[^>]*href="([^"]+)"[^>]*>([^<]+)</a>',
      );
      expect(items, hasLength(2));
      final first = items.first as List<String>;
      expect(first[0], '<a href="/book/1">书A</a>');
      expect(first[1], '/book/1');
      expect(first[2], '书A');
      final second = items.last as List<String>;
      expect(second[1], '/book/2');
      expect(second[2], '书B');
    });

    test('字段规则支持捕获组插值', () {
      final item = RuleEngine.extractElements(
        html,
        r':<a[^>]*href="([^"]+)"[^>]*>([^<]+)</a>',
      ).first as List<String>;
      expect(RuleEngine.getElementText(item, r'$0'), '<a href="/book/1">书A</a>');
      expect(RuleEngine.getElementText(item, r'$1'), '/book/1');
      expect(RuleEngine.getElementText(item, r'$2'), '书A');
      expect(
        RuleEngine.getElementText(item, r'https://example.com$1'),
        'https://example.com/book/1',
      );
    });

    test('字段规则支持 ## 正则替换后缀', () {
      final item = RuleEngine.extractElements(
        html,
        r':<a[^>]*href="([^"]+)"[^>]*>([^<]+)</a>',
      ).first as List<String>;
      expect(RuleEngine.getElementText(item, r'$2##书##BOOK'), 'BOOKA');
      expect(RuleEngine.getElementText(item, r'$1##/book/##'), '1');
      expect(RuleEngine.getElementText(item, r'$1##/book/(\d+)##X###'), 'X');
    });

    test(':正则1&&正则2 逐级缩小范围', () {
      const nested = '<main><li>1</li><li>2</li><li>3</li></main>';
      final items = RuleEngine.extractElements(
        nested,
        r':(\d+)&&\d{2,}',
      );
      // 第一段把 1/2/3 拼成 123，第二段 \d{2,} 只匹配一次
      expect(items, hasLength(1));
      expect(items.first, <String>['123']);
    });

    test('正则括号内的 && 不被当作链分隔符', () {
      final items = RuleEngine.extractElements('a&&ba&&b', r':^(a&&b)+$');
      expect(items, hasLength(1));
      expect(items.first, <String>['a&&ba&&b', 'a&&b']);
    });
  });

  group('Legado @@ 转义前缀', () {
    test('@@ 前缀作为普通 CSS 规则执行', () {
      const html = '<div class="item"><h3>书名</h3></div>';
      expect(RuleEngine.extractText(html, '@@div.item'), '书名');
      expect(RuleEngine.extractText(html, '@@div.item@text'), '书名');
      expect(
        RuleEngine.extractText(html, '@@class.item@tag.h3@text'),
        '书名',
      );
    });

    test(':contains 与 :containsOwn 文本伪类', () {
      const html = '''
        <div class="info">
          <span>类别：玄幻</span>
          <span><b>更新时间：2026</b></span>
        </div>
      ''';
      expect(
        RuleEngine.extractText(html, 'span:contains(类别：)@text'),
        '类别：玄幻',
      );
      // containsOwn 只匹配自身直接文本，不匹配仅出现在后代中的文本
      expect(
        RuleEngine.extractElements(html, 'span:containsOwn(更新时间：)'),
        isEmpty,
      );
      expect(
        RuleEngine.extractText(html, 'b:containsOwn(更新时间：)@text'),
        '更新时间：2026',
      );
    });

    test('text.xxx 前缀按自身文本包含匹配', () {
      const html = '''
        <div class="list">
          <p>作者：张三</p>
          <p>书名</p>
        </div>
      ''';
      expect(
        RuleEngine.extractText(html, 'class.list@text.作者：@text'),
        '作者：张三',
      );
    });
  });

  group('Legado ## 替换后缀（页面级）', () {
    const html = '''
      <h3 class="title">第一章 书</h3>
      <div class="content">正文内容</div>
      <a href="/book/1">链接</a>
    ''';

    test('extractText 先取规则结果再替换', () {
      expect(
        RuleEngine.extractText(html, r'h3.title##第一章\s+##'),
        '书',
      );
      expect(
        RuleEngine.extractText(html, r'div.content@text##正文##BOOK'),
        'BOOK内容',
      );
      expect(
        RuleEngine.extractText(html, r'a@href##/book/##'),
        '1',
      );
    });

    test('extractTextList 对每条结果应用替换', () {
      const listHtml = '<p class="n">A</p><p class="n">B</p>';
      expect(
        RuleEngine.extractTextList(listHtml, r'p.n@text##(A|B)##[$1]'),
        ['[A]', '[B]'],
      );
    });

    test('getElementText 元素字段与 JSONPath 字段支持替换', () {
      final item = RuleEngine.extractElements(html, 'div.content').first;
      expect(
        RuleEngine.getElementText(item, r'@text##正文##BOOK'),
        'BOOK内容',
      );
      const json = '{"name":"第一章 书"}';
      expect(
        RuleEngine.extractText(json, r'$.name##第一章\s+##'),
        '书',
      );
      expect(
        RuleEngine.extractText(html, r'//h3##第一章\s+##'),
        '书',
      );
    });
  });

  group('Legado 索引 DSL（负数/步长/排除）', () {
    const html = '<ul>'
        '<li>a</li><li>b</li><li>c</li><li>d</li><li>e</li>'
        '</ul>';

    test('cascade 负索引取倒数第 N 个', () {
      expect(
        RuleEngine.extractTextList(html, r'tag.li[-1]'),
        ['e'],
      );
    });

    test('cascade 范围含步长 [0:4:2]', () {
      expect(
        RuleEngine.extractTextList(html, r'tag.li[0:4:2]'),
        ['a', 'c', 'e'],
      );
    });

    test('cascade 排除索引 [!0]', () {
      expect(
        RuleEngine.extractTextList(html, r'tag.li[!0]'),
        ['b', 'c', 'd', 'e'],
      );
    });

    test('xpath 单索引负数取倒数', () {
      expect(
        RuleEngine.extractText(html, r'//li[-1]'),
        'e',
      );
    });
  });

}
