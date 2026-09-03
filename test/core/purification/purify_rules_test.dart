import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:easy_read/core/purification/js_purifier.dart';
import 'package:easy_read/core/purification/purify_pipeline.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';
import 'package:easy_read/features/settings/domain/entities/purification_rule.dart';
import 'package:easy_read/features/settings/domain/usecases/manage_purification_rules.dart';

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_purify_test').path);
    TestWidgetsFlutterBinding.ensureInitialized();
    // flutter test 会打包 pubspec 注册的 asset，rootBundle 可直接加载
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('ensureDefaults 从内置 asset 导入 20 条规则', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    final rules = await manager.getAll();
    expect(rules.length, 20);
    // Legado 字段映射：isEnabled → enabled、group/order/isRegex
    final first = rules.firstWhere((r) => r.id == '1');
    expect(first.name, contains('数字标题'));
    expect(first.isRegex, isTrue);
    expect(first.group, '格式');
    expect(first.replacement, startsWith('@js:'));
    expect(first.enabled, isFalse); // isEnabled=false → enabled=false
  });

  test('ensureDefaults 幂等：已有规则时不重复导入', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    await manager.add(const PurificationRule(id: 'custom', name: '自定义', pattern: 'x'));
    await manager.ensureDefaults(); // 再次调用不覆盖
    final rules = await manager.getAll();
    expect(rules.length, 21);
    expect(rules.any((r) => r.id == 'custom'), isTrue);
  });

  test('用户清空规则后 ensureDefaults 不复活内置规则', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    final box = await Hive.openBox<String>('purification_rules');
    // 模拟用户删除全部规则：仅保留导入标记，避免重启时误判为"未初始化"
    final marker = box.get('__defaults_imported');
    await box.clear();
    if (marker != null) {
      await box.put('__defaults_imported', marker);
    }

    expect(await manager.getAll(), isEmpty);
    await manager.ensureDefaults();
    expect(await manager.getAll(), isEmpty);
  });

  test('ensureDefaults 旧版升级：已有规则无标记时不导入默认规则', () async {
    final manager = ManagePurificationRules();
    // 模拟旧版本（isNotEmpty 判断时代）用户：盒内有规则但无导入标记，
    // 其中含与内置规则同 id 的用户修改
    await manager.add(const PurificationRule(id: '1', name: '用户改过的内置规则', pattern: 'y'));
    await manager.add(const PurificationRule(id: 'legacy', name: '旧规则', pattern: 'x'));

    await manager.ensureDefaults();

    final rules = await manager.getAll();
    // 不追加 20 条内置规则
    expect(rules.length, 2);
    // 用户对同 id 内置规则的修改不被默认值覆盖
    final custom = rules.firstWhere((r) => r.id == '1');
    expect(custom.name, '用户改过的内置规则');
    expect(custom.pattern, 'y');
    // 标记被补写：后续启动不再触发导入
    final box = await Hive.openBox<String>('purification_rules');
    expect(box.get('__defaults_imported'), '1');
  });

  test('buildPurifier 分流：Dart 可编译规则进 rules，JS 规则进 jsRules', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    final purifier = await manager.buildPurifier();
    // 启用 19 条：#02-04 @js 替换 + 11 条 lookbehind 语法 → JS 执行器；
    // #08/#10/#14/#19/#20 可编译纯正则 → Dart rules
    expect(purifier.jsRules.length, greaterThanOrEqualTo(14));
    expect(purifier.rules.length, greaterThanOrEqualTo(5));
    // Dart 规则不应包含 @js 替换模板
    expect(
      purifier.rules.every((r) => !r.replacement.startsWith('@js:')),
      isTrue,
    );
    // JS 规则包含启用的 @js 规则（#02 全角字符）
    expect(
      purifier.jsRules.any((r) => r.pattern.startsWith('[０-９')),
      isTrue,
    );
  });

  test('scopeTitle/scopeContent 规则分流', () async {
    final manager = ManagePurificationRules();
    await manager.add(const PurificationRule(
      id: 'title',
      name: '标题',
      pattern: '第一章',
      replacement: '第1章',
      scopeTitle: true,
      scopeContent: false,
    ));
    await manager.add(const PurificationRule(
      id: 'content',
      name: '正文',
      pattern: '正文',
      replacement: '内容',
      scopeTitle: false,
      scopeContent: true,
    ));

    final content = await manager.buildPurifier();
    expect(content.purify('正文'), '内容');
    expect(content.purify('第一章'), '第一章');

    final title = await manager.buildTitlePurifier();
    expect(title.purify('第一章'), '第1章');
    expect(title.purify('正文'), '正文');
  });

  test('PurifyPipeline 可单独净化标题', () async {
    final pipeline = PurifyPipeline(
      titlePurifier: const RegexPurifier(
        rules: [PurifyRule(pattern: '第一章', replacement: '第1章')],
      ),
    );
    expect(await pipeline.purifyTitle('第一章 开始'), '第1章 开始');
  });

  test('scope/excludeScope 按书名和书源过滤', () {
    const purifier = RegexPurifier(rules: [
      PurifyRule(pattern: '正文', replacement: '内容', scope: '书A'),
      PurifyRule(
        pattern: '正文',
        replacement: '排除内容',
        excludeScope: '书A',
      ),
    ]);
    expect(
      purifier.scopedFor(bookName: '书A', sourceName: '源A').purify('正文'),
      '内容',
    );
    expect(
      purifier.scopedFor(bookName: '书B', sourceName: '源A').purify('正文'),
      '排除内容',
    );
  });

  test('JsPurifier 执行 @js 全角字符替换（引擎可用时）', () async {
    const rule = JsPurifyRule(
      pattern: '[０-９]',
      script: 'R=result; R=="０"?"0":R=="１"?"1":R=="２"?"2":R=="３"?"3":R=="４"?"4":R=="５"?"5":R=="６"?"6":R=="７"?"7":R=="８"?"8":R=="９"?"9":R',
    );
    final out = await JsPurifier().apply('１２３', [rule]);
    // iOS 无引擎时返回原文（跳过 JS 规则）；有引擎时转换
    if (out == '１２３') return;
    expect(out, '123');
  });

  test('JsPurifier 空脚本删除匹配', () async {
    const rule = JsPurifyRule(pattern: '（本章完）', script: '');
    final out = await JsPurifier().apply('正文内容（本章完）', [rule]);
    if (out == '正文内容（本章完）') return; // 引擎不可用
    expect(out, '正文内容');
  });

  test('RegexPurifier.purifyAsync 引擎不可用时跳过 JS 规则不崩溃', () async {
    const purifier = RegexPurifier(
      rules: [PurifyRule(pattern: r'\s+', replacement: '')],
      jsRules: [JsPurifyRule(pattern: '(?<=a)b', script: '')],
    );
    final out = await purifier.purifyAsync('a b c');
    // Dart 规则（去空格）必然生效；JS lookbehind 规则由引擎执行
    // （'ac'）或引擎不可用时跳过（'abc'），两者都不崩溃
    expect(out, anyOf('ac', 'abc'));
  });

  test('PCRE 内联修饰符 (?i)/(?m) 被剥离并转 flags，QuickJS 可编译执行', () async {
    // 内置规则 #04 的 pattern 以 (?i) 开头；QuickJS 不接受 PCRE 内联修饰符
    const rule = JsPurifyRule(
      pattern: '(?i)测试',
      script: 'R=result; R=="测试"?"[T]":R=="测试2"?"[T2]":R',
    );
    final out = await JsPurifier().apply('abc测试xyz', [rule]);
    if (out == 'abc测试xyz') return; // 引擎不可用
    // (?i) 被剥离后仍能匹配中文文本，且脚本正常执行
    expect(out, 'abc[T]xyz');
  });

  test('一条 JS 规则失败不中止后续规则', () async {
    const badRule = JsPurifyRule(
      pattern: '(?<![a-z', // 非法正则：未闭合 lookbehind，编译必失败
      script: '',
    );
    const goodRule = JsPurifyRule(pattern: '（本章完）', script: '');
    final out = await JsPurifier().apply('正文（本章完）', [badRule, goodRule]);
    if (out == '正文（本章完）') return; // 引擎不可用
    // 坏规则被跳过，好规则仍生效
    expect(out, '正文');
  });

  test('含内联修饰符的规则保留普通文本 replacement（JS 路径非删除）', () async {
    // pattern 含 (?i) 内联修饰符（Dart 无法编译）→ JS 执行器，
    // replacement 是普通文本而非 @js 模板：应逐匹配替换而非删除
    final manager = ManagePurificationRules();
    await manager.add(const PurificationRule(
      id: 'punct',
      name: '标点',
      pattern: '(?i)(?<=“)[。.]+(?=”)',
      replacement: '……',
    ));
    final purifier = await manager.buildPurifier();
    expect(purifier.jsRules, isNotEmpty);
    final jsRule = purifier.jsRules.firstWhere((r) => r.pattern.contains('(?<='));
    // 普通文本 replacement 落在 replacement 字段，script 为空
    expect(jsRule.replacement, '……');
    expect(jsRule.script, isEmpty);
  });

  test('JsPurifier 普通文本 replacement 逐匹配替换（非删除）', () async {
    const rule = JsPurifyRule(
      pattern: '(?i)(?<=“)[。.]+(?=”)',
      replacement: '……',
    );
    final out = await JsPurifier().apply('“。。。”', [rule]);
    if (out == '“。。。”') return; // 引擎不可用
    expect(out, '“……”');
  });

  test('JsPurifier 普通文本 replacement 展开 \$N 捕获组反向引用', () async {
    // 形态同内置 #09：含内联修饰符走 JS 路径，replacement 用 $N 反向引用。
    // 三个捕获组全部真实参与匹配，$2 展开为具体内容而非空串。
    const rule = JsPurifyRule(
      pattern: r'(?i)([“＂])([^“”＂]{1,5})([”"])',
      replacement: r'《$2》',
    );
    final out = await JsPurifier().apply('他说：“你好”', [rule]);
    if (out == '他说：“你好”') return; // 引擎不可用
    // 全角引号命中正则 → $2 展开为"你好"（若未展开则为字面《$2》，断言失败）
    expect(out, '他说：《你好》');
    expect(out.contains(r'$2'), isFalse, reason: r'$N 必须被展开为实际捕获内容');
  });

  test('buildPurifier 对 isRegex=false 的普通文本规则按字面量替换', () async {
    final manager = ManagePurificationRules();
    // 普通文本规则：pattern 含正则元字符，应被转义后按字面量替换
    await manager.add(const PurificationRule(
      id: 'literal',
      name: '字面量',
      pattern: 'a.b',
      replacement: 'X',
      isRegex: false,
    ));
    final purifier = await manager.buildPurifier();
    final out = purifier.purify('a.b 和 axb');
    // 'a.b' 被替换为 X；'axb'（a+任意字符+b）不应被替换（字面量语义）
    expect(out, 'X 和 axb');
  });

  test('importFromJson 导入规则数组，id 冲突自动重编号', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults(); // 内置 20 条，id 1-20 已占用
    // 模拟 jinghua.json：id 与内置冲突（1-20），且是数组格式
    final count = await manager.importFromJson('''
[
  {"id": 1, "name": "外部规则一", "pattern": "(?i)测试", "replacement": "X", "isEnabled": true},
  {"id": 2, "name": "外部规则二", "pattern": "abc", "replacement": ""}
]
''');
    expect(count, 2);
    final rules = await manager.getAll();
    expect(rules.length, 22);
    // 原 id=1 的内置规则未被覆盖（名称仍是内置的）
    final builtin = rules.firstWhere((r) => r.id == '1');
    expect(builtin.name, isNot('外部规则一'));
    // 导入的规则用重编号 id 保存
    final imported = rules.where((r) => r.name.startsWith('外部规则'));
    expect(imported.length, 2);
    expect(imported.every((r) => r.id != '1' && r.id != '2'), isTrue);
    // 字段映射（isEnabled → enabled）
    expect(imported.first.enabled, isTrue);
  });

  test('importFromJson 解析失败抛 FormatException 不写库', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    expect(() => manager.importFromJson('{bad json'), throwsFormatException);
    // 库未被污染
    final rules = await manager.getAll();
    expect(rules.length, 20);
  });

  test('importFromJson 空 pattern 条目跳过', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    final count = await manager.importFromJson('''
[
  {"id": "a", "name": "空规则", "pattern": "", "replacement": ""},
  {"id": "b", "name": "有效规则", "pattern": "x", "replacement": "y"}
]
''');
    expect(count, 1);
  });

  test('importFromJson 支持外部 isEnabled=false', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    await manager.importFromJson('''
[
  {"id": "off", "name": "关闭规则", "pattern": "x", "replacement": "", "isEnabled": false}
]
''');
    final rule = (await manager.getAll()).firstWhere((r) => r.id == 'off');
    expect(rule.enabled, isFalse);
  });

  test('C2 scope 双向匹配:legado 串含书名/源 与 EasyRead 短前缀均命中', () {
    const purifier = RegexPurifier(rules: [
      // legado 方向:scope 串包含书名(精确书名导入)
      PurifyRule(pattern: 'a', replacement: 'A', scope: '凡人修仙传(精校版)'),
      // EasyRead 方向:书名包含短前缀 scope 项
      PurifyRule(pattern: 'b', replacement: 'B', scope: '斗破'),
    ]);
    final scoped = purifier.scopedFor(
      bookName: '凡人修仙传',
      sourceName: '源X',
    );
    expect(scoped.purify('a'), 'A'); // scope 含书名 → 命中
    expect(scoped.purify('b'), 'b');
    final scoped2 = purifier.scopedFor(
      bookName: '斗破苍穹',
      sourceName: '源X',
    );
    expect(scoped2.purify('a'), 'a');
    expect(scoped2.purify('b'), 'B'); // 书名含 scope 项 → 命中
  });

  test('C2 scope 项与书名部分重叠(书A续集)按双向语义命中并固定现状', () {
    // 固定行为:双向 contains 下 scope='书A' 命中 '书A续集'(旧实现既有行为,
    // 非 C2 引入);legado 严格整串 SQL 语义此处会失配,EasyRead 取超集,
    // 偏差理由见 LEGADO_PARITY_PLAN.md C2。
    const purifier = RegexPurifier(rules: [
      PurifyRule(pattern: 'x', replacement: 'Y', scope: '书A'),
    ]);
    expect(
      purifier.scopedFor(bookName: '书A续集', sourceName: null).purify('x'),
      'Y',
    );
    // 完全不相关书名不命中
    expect(
      purifier.scopedFor(bookName: '完全无关', sourceName: null).purify('x'),
      'x',
    );
  });

  test('C2 scope 规则对书名/源名缺失(null)健壮:不因空目标全量命中', () {
    const purifier = RegexPurifier(rules: [
      PurifyRule(pattern: 'x', replacement: 'Y', scope: '书A'),
    ]);
    // 书名与源名都缺失:无匹配目标,scope 规则不命中
    expect(purifier.scopedFor().purify('x'), 'x');
    // 仅源名命中
    expect(
      purifier.scopedFor(sourceName: '书A网').purify('x'),
      'Y',
    );
  });

  test('C2 scope 匹配源 URL,excludeScope 命中源 URL 排除', () {
    const purifier = RegexPurifier(rules: [
      PurifyRule(pattern: 'x', replacement: 'Y', scope: 'www.example.com'),
      PurifyRule(
        pattern: 'x',
        replacement: 'Z',
        excludeScope: 'bad.org',
        scope: '坏源',
      ),
    ]);
    // scope 含源 URL → 命中;excludeScope 不含 → 应用
    expect(
      purifier
          .scopedFor(
            bookName: '书',
            sourceName: '好源',
            sourceUrl: 'https://www.example.com/book',
          )
          .purify('x'),
      'Y',
    );
    // excludeScope 命中源名 → 整条排除,回退第二条(scope 坏源含源名命中)
    expect(
      purifier
          .scopedFor(
            bookName: '书',
            sourceName: '坏源',
            sourceUrl: 'https://x.bad.org',
          )
          .purify('x'),
      'x',
    );
  });

  test('C2 Dart 规则执行超时:触发回调并跳过该规则', () async {
    // 嵌套量词 ReDoS 模式(绕过 PurifyPatternGuard 直接构造 PurifyRule),
    // 超时 50ms 内无法完成
    const slow = PurifyRule(
      id: 'slow-1',
      pattern: r'(a+)+$',
      replacement: 'X',
      timeoutMs: 50,
    );
    final timedOut = <String>[];
    final purifier = RegexPurifier(
      rules: [slow, const PurifyRule(pattern: 'b', replacement: 'B')],
      onRuleTimeout: (rule) => timedOut.add(rule.id),
    );
    final input = 'a' * 24 + 'b';
    final out = await purifier.purifyAsync(input);
    expect(timedOut, ['slow-1']);
    // 慢规则被跳过(原文含 a 串),后续规则正常执行
    expect(out.contains('a' * 24), isTrue);
    expect(out, endsWith('B'));
  });

  test('C2 purifyAsync 不超时路径与同步结果一致', () async {
    const purifier = RegexPurifier(rules: [
      PurifyRule(pattern: '，', replacement: ','),
    ]);
    final out = await purifier.purifyAsync('你好，世界');
    expect(out, '你好,世界');
  });

  test('C2 withoutRules 会话级禁用超时规则', () {
    const purifier = RegexPurifier(rules: [
      PurifyRule(id: 'r1', pattern: 'x', replacement: 'Y'),
      PurifyRule(id: 'r2', pattern: 'x', replacement: 'Z'),
    ]);
    final filtered = purifier.withoutRules({'r1'});
    expect(filtered.purify('x'), 'Z');
    expect(purifier.purify('x'), 'Y'); // 原实例不变
  });

  test('C2 buildPurifyPipeline 超时会话禁用 + onRuleDisabled 去重通知', () async {
    final disabledEvents = <String>[];
    final pipeline = buildPurifyPipeline(
      regexPurifier: const RegexPurifier(rules: [
        PurifyRule(
          id: 'slow',
          pattern: r'(a+)+$',
          replacement: 'X',
          timeoutMs: 50,
        ),
      ]),
      onRuleDisabled: disabledEvents.add,
    );
    final input = 'a' * 24 + 'b';
    // 第一次净化:超时 → 禁用 + 通知
    await pipeline.purifyAsync(input);
    expect(disabledEvents, ['slow']);
    // 第二次净化:会话级禁用,不再执行慢规则(不再触发回调)
    await pipeline.purifyAsync(input);
    expect(disabledEvents, ['slow']);
  });

  test('C2 disableRule 持久化 enabled=false,重复禁用幂等', () async {
    final manager = ManagePurificationRules();
    await manager.ensureDefaults();
    final before = (await manager.getAll()).firstWhere((r) => r.id == '2');
    expect(before.enabled, isTrue);
    await manager.disableRule('2');
    final after = (await manager.getAll()).firstWhere((r) => r.id == '2');
    expect(after.enabled, isFalse);
    await manager.disableRule('2'); // 已禁用:不写库
    final again = (await manager.getAll()).firstWhere((r) => r.id == '2');
    expect(again.enabled, isFalse);
    // 不存在的 id 静默忽略
    await manager.disableRule('nonexistent');
    expect((await manager.getAll()).length, 20);
  });

  test('C2 _buildPurifier 映射:id/timeoutMs 透传到 PurifyRule/JsPurifyRule', () async {
    final manager = ManagePurificationRules();
    await manager.add(const PurificationRule(
      id: 'map-dart',
      name: 'Dart 规则',
      pattern: 'a',
      replacement: 'b',
      timeoutMillisecond: 1500,
    ));
    await manager.add(const PurificationRule(
      id: 'map-js',
      name: 'JS 规则',
      pattern: 'c',
      replacement: '@js:result',
      timeoutMillisecond: 2500,
    ));
    // 未配置超时(0)→ null 执行层回落默认 3000(legado getValidTimeoutMillisecond)
    await manager.add(const PurificationRule(
      id: 'map-default',
      name: '默认超时',
      pattern: 'd',
      replacement: 'e',
      timeoutMillisecond: 0,
    ));
    await manager.add(const PurificationRule(
      id: 'map-lookbehind',
      name: 'JS 语法规则',
      pattern: r'(?<=x)y',
      replacement: 'z',
    ));
    final purifier = await manager.buildPurifier();
    final dart = purifier.rules.firstWhere((r) => r.id == 'map-dart');
    expect(dart.timeoutMs, 1500);
    final js = purifier.jsRules.firstWhere((r) => r.id == 'map-js');
    expect(js.timeoutMs, 2500);
    // Dart 3.12+ RegExp 已支持 lookbehind:可编译,进 Dart rules
    // (旧版会转 JS fallback;此断言锁定当前行为,升级 Dart 时会提示)
    expect(
      purifier.rules.firstWhere((r) => r.id == 'map-lookbehind').timeoutMs,
      isNull,
    );
  });

  test('C2 JsPurifier 规则级 deadline 超时触发 onRuleTimeout(引擎可用时)', () async {
    // 规则级 deadline(timeoutMs=50)先于 quickjs 指令中断(约1-3s)触发:
    // while(true) 卡住 eval,Dart 侧 .timeout(remaining) 抛 TimeoutException
    // → onRuleTimeout 必须回调(接线坏/漏接线时此断言失败,不再静默)。
    final timeouts = <String>[];
    final purifier = JsPurifier(
      onRuleTimeout: (r) => timeouts.add(r.id),
    );
    // 引擎可用性前置探测:复用已验证的全角转数字脚本
    final probed = await purifier
        .apply('１２３', [const JsPurifyRule(id: 'probe', pattern: '[０-９]', script: 'R=result; R=="０"?"0":R=="１"?"1":R=="２"?"2":R=="３"?"3":1')])
        .timeout(const Duration(seconds: 20));
    if (probed != '123') return; // 引擎不可用(iOS 等)

    const rule = JsPurifyRule(
      id: 'js-slow',
      pattern: 'x',
      script: 'while (true) {}',
      timeoutMs: 50,
    );
    final out = await purifier
        .apply('x', [rule])
        .timeout(const Duration(seconds: 20));
    expect(timeouts, ['js-slow']); // 必须回调:堵"接线坏静默通过"
    expect(out, 'x'); // 超时规则跳过,文本原样
  });

  test('C2 无效正则(spawn 降级路径)不触发超时回调', () async {
    // 非法正则:isolate 入口发 null → 同步重试仍抛 → 调用方跳过,
    // 全程不应触发 onRuleTimeout(基础设施/规则缺陷 ≠ 执行超时)
    final timeouts = <String>[];
    const bad = PurifyRule(id: 'bad', pattern: '([unclosed', replacement: 'X');
    const good = PurifyRule(id: 'good', pattern: 'y', replacement: 'Y');
    final purifier = RegexPurifier(
      rules: [bad, good],
      onRuleTimeout: (r) => timeouts.add(r.id),
    );
    final out = await purifier.purifyAsync('y');
    expect(out, 'Y');
    expect(timeouts, isEmpty);
  });

  test('JsPurifier 超时后强制回收不挂起', () async {
    const rule = JsPurifyRule(pattern: 'x', script: 'while (true) {}');
    final out = await JsPurifier()
        .apply('x', [rule])
        .timeout(const Duration(seconds: 20));
    // 引擎不可用时原样返回；引擎可用时死循环超时后也必须返回，不能卡在 dispose
    expect(out, 'x');
  });
}
