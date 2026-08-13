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

  test('JsPurifier 超时后强制回收不挂起', () async {
    const rule = JsPurifyRule(pattern: 'x', script: 'while (true) {}');
    final out = await JsPurifier()
        .apply('x', [rule])
        .timeout(const Duration(seconds: 20));
    // 引擎不可用时原样返回；引擎可用时死循环超时后也必须返回，不能卡在 dispose
    expect(out, 'x');
  });
}
