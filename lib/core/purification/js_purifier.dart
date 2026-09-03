import 'dart:async';
import 'dart:convert';
import 'package:easy_quickjs/quickjs.dart';
import 'regex_purifier.dart';

/// 基于 quickjs 的 JS 净化执行器。
///
/// 处理 Dart RegExp 无法编译的规则（JS lookbehind 语法）与 `@js:` 替换
/// 模板。Legado 语义：
/// - 每条规则的 pattern 编译为 JS 正则，逐匹配收集；
/// - 对每个匹配执行 `result = <匹配文本>; <script>`，最后表达式的值
///   作为替换文本（空脚本 = 删除匹配）。
///
/// 引擎管理复用 quickjs isolate：进程级单例 manager，初始化失败
/// （如 iOS native assets 不可用）返回 null 由调用方跳过 JS 规则。
class JsPurifier {
  /// 单条 JS 规则超时回调(参数为规则,空 id 不回调由调用方判断)
  final void Function(JsPurifyRule rule)? onRuleTimeout;

  JsPurifier({this.onRuleTimeout});

  static JsEngineManager? _manager;
  static Future<JsEngineManager?>? _managerInit;
  static int _engineSeq = 0;

  /// 上次初始化失败时间：平台无引擎（如 iOS）时 5 分钟内不重试，
  /// 避免每次净化都触发 5s 超时挂起
  static DateTime? _lastFailTime;

  Future<JsEngineManager?> _getManager() {
    final failed = _lastFailTime;
    if (failed != null &&
        DateTime.now().difference(failed) < const Duration(minutes: 5)) {
      return Future.value(null);
    }
    final pending = _managerInit;
    if (pending != null) return pending;
    final future = _initManager();
    _managerInit = future;
    return future;
  }

  /// 引擎初始化超时：engineIsolate 启动失败（如 native 库缺失）时
  /// receivePort.first 永不返回导致挂起，必须限时降级
  static const Duration _initTimeout = Duration(seconds: 5);

  /// 单次 eval 超时（防异常正则/脚本死循环卡死净化）
  static const Duration _evalTimeout = Duration(seconds: 3);

  Future<JsEngineManager?> _initManager() async {
    try {
      final manager = await JsEngineManager.create().timeout(_initTimeout);
      _manager = manager;
      return manager;
    } catch (_) {
      // 平台无 quickjs 原生库 / 初始化超时 → 降级：JS 规则跳过，
      // 短时缓存失败状态避免反复触发超时
      _managerInit = null;
      _lastFailTime = DateTime.now();
      return null;
    }
  }

  /// 强制回收当前 manager：eval 超时后原生 isolate 仍可能被 JS 卡住，
  /// 不能再向它发送 dispose 命令（会永远等不到响应），必须直接 kill。
  static Future<void> _forceDisposeManager() async {
    final old = _manager;
    _manager = null;
    _managerInit = null;
    _lastFailTime = null;
    if (old != null) {
      try {
        await old.forceDispose();
      } catch (_) {}
    }
  }

  /// 按规则列表净化 [input]；引擎不可用时返回原文本。
  Future<String> apply(String input, List<JsPurifyRule> rules) async {
    var manager = await _getManager();
    if (manager == null) return input;
    // 多条规则共用一个 engine：避免每条规则各起一个 isolate engine
    // （20 条 JS 规则否则要创建/销毁 20 次，显著拖慢每章净化）
    JsEngine? engine = await manager.createEngine('purify${_engineSeq++}');
    try {
      var result = input;
      for (var i = 0; i < rules.length; i++) {
        try {
          result = await _applyRule(engine!, result, rules[i]);
        } on TimeoutException {
          // 单条规则超时:先走优雅协议回收(指令中断后 isolate 可正常
          // 退场,dispose 响应正常返回),100ms 内无响应才硬杀——
          // 直接 kill 卡在 FFI eval 的 isolate,其退场要等原生调用返回,
          // 测试 runner/宿主等待该 isolate 时会表现为后续任务挂起。
          onRuleTimeout?.call(rules[i]);
          try {
            await engine?.dispose().timeout(const Duration(milliseconds: 100));
          } catch (_) {}
          await _forceDisposeManager();
          engine = null;
          if (i == rules.length - 1) return result;
          final next = await _getManager();
          if (next == null) return result;
          manager = next;
          engine = await manager.createEngine('purify${_engineSeq++}');
        } catch (_) {
          // 单条规则正则非法/脚本异常:跳过该条,不影响其他规则
        }
      }
      return result;
    } finally {
      try {
        await engine?.dispose();
      } catch (_) {}
    }
  }

  Future<String> _applyRule(
    JsEngine engine,
    String input,
    JsPurifyRule rule,
  ) async {
    // 规则级超时预算(legado timeoutMillisecond 语义):deadline 覆盖
    // 匹配收集 + 全部匹配的替换脚本执行,而非每个匹配各享一份 3s。
    final deadline = DateTime.now().add(
      Duration(milliseconds: rule.timeoutMs ?? kPurifyDefaultTimeoutMs),
    );
    final matches = await _collectMatches(engine, rule.pattern, input)
        .timeout(deadline.difference(DateTime.now()));
    if (matches.isEmpty) return input;
    var sb = StringBuffer();
    var cursor = 0;
    for (final m in matches) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('净化规则超时: ${rule.pattern}');
      }
      sb.write(input.substring(cursor, m.start));
      // 普通文本 replacement（非 @js 模板）：逐匹配替换，
      // 展开 $N 捕获组反向引用（Legado 语义，如 #09 标点＂＂ → “$2”）
      if (rule.script.isEmpty) {
        sb.write(_expandCaptures(rule.replacement, m));
      } else {
        sb.write(await _transform(engine, rule.script, m.text)
            .timeout(remaining));
      }
      cursor = m.end;
    }
    sb.write(input.substring(cursor));
    return sb.toString();
  }

  /// 展开 replacement 中的 `$N` 捕获组反向引用（N = 0 为整个匹配，
  /// 与 JS `String.replace` 语义一致）。捕获组缺失时替换为空串。
  static String _expandCaptures(String replacement, _JsMatch match) {
    if (!replacement.contains(r'$')) return replacement;
    return replacement.replaceAllMapped(
      RegExp(r'\$\$|\$&|\$(\d+)'),
      (m) {
        if (m.group(0) == r'$$') return r'$';
        if (m.group(0) == r'$&') return match.text;
        final index = int.parse(m.group(1)!);
        if (index == 0) return match.text;
        if (index <= match.groups.length) {
          return match.groups[index - 1] ?? '';
        }
        return '';
      },
    );
  }

  /// JS 正则收集匹配（JS 语法含 lookbehind，Dart 侧无法编译）。
  /// 必须带 `g` flag：无 g 时 exec 不推进 lastIndex 会死循环。
  Future<List<_JsMatch>> _collectMatches(
    JsEngine engine,
    String pattern,
    String input,
  ) async {
    // 内置规则使用 PCRE 内联修饰符（(?i)/(?m)/(?mi)），QuickJS 的 RegExp
    // 不接受这种语法。剥离后转成标准 flags（JS RegExp 无内联修饰符语义，
    // 取并集近似：i/m 修饰符出现即全局开启，对净化场景可接受）。
    final (clean, flags) = _stripInlineModifiers(pattern);
    final result = await engine.eval('''
(() => {
  const re = new RegExp(${_quote(clean)}, ${_quote('g$flags')});
  const input = ${_quote(input)};
  const out = [];
  let m;
  while ((m = re.exec(input)) !== null) {
    out.push({ s: m.index, t: m[0], g: Array.prototype.slice.call(m, 1) });
    if (m[0] === '') re.lastIndex++;
  }
  return JSON.stringify(out);
})()
''').timeout(_evalTimeout);
    final parsed = _tryParseJson(result.value);
    return [
      for (final item in parsed)
        _JsMatch(
          start: (item['s'] as num?)?.toInt() ?? 0,
          end: ((item['s'] as num?)?.toInt() ?? 0) + ((item['t'] as String?)?.length ?? 0),
          text: item['t'] as String? ?? '',
          groups: [
            for (final g in (item['g'] as List? ?? const []))
              g as String?,
          ],
        ),
    ];
  }

  /// 剥离 PCRE 内联修饰符 `(?i)`/`(?m)`/`(?s)`，返回 (清洗后的正则, 收集的 flags)。
  /// 修饰符在规则中的任意位置出现均视为对该规则生效（取并集近似，
  /// 与 PCRE 的"作用于其后分支"语义略有差异，但对净化场景可接受）。
  static (String, String) _stripInlineModifiers(String pattern) {
    final re = RegExp(r'\(\?([ims]+)\)');
    final buffer = StringBuffer();
    var last = 0;
    var flags = '';
    for (final m in re.allMatches(pattern)) {
      buffer.write(pattern.substring(last, m.start));
      for (final ch in m.group(1)!.split('')) {
        if (!flags.contains(ch)) flags += ch;
      }
      last = m.end;
    }
    buffer.write(pattern.substring(last));
    return (buffer.toString(), flags);
  }

  /// 对单个匹配执行替换脚本：result = 匹配文本，最后表达式值 = 替换文本
  Future<String> _transform(JsEngine engine, String script, String match) async {
    if (script.trim().isEmpty) return '';
    final result = await engine
        .eval('globalThis.result = ${_quote(match)};\n$script')
        .timeout(_evalTimeout);
    final value = result.value;
    return value == 'undefined' ? '' : value;
  }

  static List<Map<String, dynamic>> _tryParseJson(String json) {
    try {
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  static String _quote(String s) {
    // 用 JSON 转义注入 JS 字符串字面量，安全处理换行/引号
    return jsonEncode(s);
  }
}

/// JS 正则匹配结果（Dart 侧重放用）
class _JsMatch {
  final int start;
  final int end;
  final String text;

  /// 捕获组内容（$1、$2…），未参与匹配的组为 null
  final List<String?> groups;

  const _JsMatch({
    required this.start,
    required this.end,
    required this.text,
    this.groups = const [],
  });
}
