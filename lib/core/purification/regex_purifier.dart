import 'dart:async';
import 'dart:isolate';

import 'js_purifier.dart';

/// 单条规则超时未配置时的默认值(Legado 默认 3000ms)
const int kPurifyDefaultTimeoutMs = 3000;

/// 单个替换规则(Dart RegExp 执行)
class PurifyRule {
  /// 规则 id(来自 PurificationRule,超时回调定位持久化记录用)
  final String id;
  final String pattern;
  final String replacement;
  final bool caseSensitive;
  final String? scope;
  final String? excludeScope;

  /// 单规则执行超时(毫秒);null 用 [kPurifyDefaultTimeoutMs]
  final int? timeoutMs;

  /// replacement 是否按纯字面量替换（isRegex=false 的普通文本规则）。
  /// 对齐 Legado ContentProcessor：非正则规则走 Kotlin String.replace
  /// 纯字面替换（不展开 $N），正则规则走 appendReplacement（展开 $N）。
  final bool literalReplacement;

  const PurifyRule({
    this.id = '',
    required this.pattern,
    required this.replacement,
    this.caseSensitive = false,
    this.scope,
    this.excludeScope,
    this.timeoutMs,
    this.literalReplacement = false,
  });

  RegExp get regex => RegExp(pattern, caseSensitive: caseSensitive);
}

/// 需 JS 引擎执行的净化规则:
/// - pattern 含 JS 特有语法(如 lookbehind `(?<=...)`,Dart RegExp 不支持)
/// - [script] 为 `@js:` 替换模板(脚本内 `result` = 匹配文本,
///   脚本最后表达式的值 = 替换文本)
/// - [replacement] 为普通文本替换内容(非 JS 模板时的替换文本;
///   为空且 [script] 为空 = 删除匹配)
class JsPurifyRule {
  final String id;
  final String pattern;
  final String script;
  final String replacement;
  final String? scope;
  final String? excludeScope;

  /// 单规则执行超时(毫秒);null 用 [kPurifyDefaultTimeoutMs]
  final int? timeoutMs;

  const JsPurifyRule({
    this.id = '',
    required this.pattern,
    this.script = '',
    this.replacement = '',
    this.scope,
    this.excludeScope,
    this.timeoutMs,
  });
}

/// 正则净化 - 按规则列表逐条替换。
/// Dart 规则在独立 Isolate 逐条执行,单条超时(防 ReDoS 卡死事件循环)
/// 触发 [onRuleTimeout] 后跳过继续;JS 规则交 [JsPurifier]
/// (引擎不可用时静默跳过)。
class RegexPurifier {
  final List<PurifyRule> rules;
  final List<JsPurifyRule> jsRules;

  /// Dart 规则执行超时回调(参数为规则 id,空 id 不回调)
  final void Function(PurifyRule rule)? onRuleTimeout;

  /// JS 规则执行超时回调
  final void Function(JsPurifyRule rule)? onJsRuleTimeout;

  /// 正则编译缓存上限:净化规则数量级小,超限整体清空(代价可忽略)
  static const int _regexCacheMax = 256;
  static final Map<String, RegExp> _regexCache = {};

  const RegexPurifier({
    this.rules = const [],
    this.jsRules = const [],
    this.onRuleTimeout,
    this.onJsRuleTimeout,
  });

  /// 按书名/书源名/书源 URL 过滤 Legado scope/excludeScope 后返回新的执行器。
  RegexPurifier scopedFor({
    String? bookName,
    String? sourceName,
    String? sourceUrl,
  }) {
    return _filtered((scope, excludeScope) =>
        _matchesScope(scope, excludeScope, bookName, sourceName, sourceUrl));
  }

  /// 排除指定 id 的规则(会话级禁用:超时后不再执行)。
  RegexPurifier withoutRules(Set<String> disabledIds) {
    if (disabledIds.isEmpty) return this;
    return _filtered((_, _) => true,
        keepDart: (r) => !disabledIds.contains(r.id),
        keepJs: (r) => !disabledIds.contains(r.id));
  }

  RegexPurifier _filtered(
    bool Function(String? scope, String? excludeScope) predicate, {
    bool Function(PurifyRule)? keepDart,
    bool Function(JsPurifyRule)? keepJs,
  }) {
    return RegexPurifier(
      rules: [
        for (final rule in rules)
          if (keepDart?.call(rule) ?? true)
            if (predicate(rule.scope, rule.excludeScope)) rule,
      ],
      jsRules: [
        for (final rule in jsRules)
          if (keepJs?.call(rule) ?? true)
            if (predicate(rule.scope, rule.excludeScope)) rule,
      ],
      onRuleTimeout: onRuleTimeout,
      onJsRuleTimeout: onJsRuleTimeout,
    );
  }

  /// Legado scope/excludeScope 语义(ReplaceRuleDao SQL):
  /// `scope LIKE '%' || :name || '%'` —— scope 串包含书名/源 origin;
  /// excludeScope 包含书名/源 origin 时排除。
  /// 兼容双向 contains:scope 项包含书名(Legado 精确书名/源 URL 导入规则)
  /// 或书名包含 scope 项(EasyRead 短前缀习惯)均命中。
  /// 书名/源名/源 URL 分别独立匹配,任一命中即生效。
  static bool _matchesScope(
    String? scope,
    String? excludeScope,
    String? bookName,
    String? sourceName,
    String? sourceUrl,
  ) {
    final targets = [
      for (final t in [bookName, sourceName, sourceUrl])
        if (t != null && t.trim().isNotEmpty) t.trim(),
    ];
    bool hit(String raw) {
      final item = raw.trim();
      if (item.isEmpty || targets.isEmpty) return false;
      return targets.any((t) => t.contains(item) || item.contains(t));
    }

    if (excludeScope != null && excludeScope.trim().isNotEmpty) {
      for (final item in excludeScope.split(',')) {
        if (hit(item)) return false;
      }
    }
    if (scope == null || scope.trim().isEmpty) return true;
    for (final item in scope.split(',')) {
      if (hit(item)) return true;
    }
    return false;
  }

  /// 展开 replacement 中的捕获组反向引用（对齐 Legado 非 JS 路径的
  /// Java appendReplacement 语义，RegexExtensions.kt:43；与 JS 路径
  /// js_purifier._expandCaptures 保持同一套约定，消除双路径不一致）：
  /// - `$N`：第 N 个捕获组（`$0` = 整个匹配）；组不存在 → 空串
  ///   （Legado 对不存在的组直接抛错弃整条规则，此处取空更宽容）
  /// - `$&`：整个匹配（Java 无此语法会抛错，按 JS 习惯统一支持）
  /// - `$$` / `\$`：字面 `$`（后者兼容 Legado 存量规则的 Java 转义写法）
  /// - 其余孤立 `$`：保持字面
  static String expandCaptures(String replacement, Match m) {
    if (!replacement.contains(r'$') && !replacement.contains(r'\')) {
      return replacement;
    }
    return replacement.replaceAllMapped(
      RegExp(r'\$\$|\$&|\\\$|\$(\d+)'),
      (d) {
        if (d.group(0) == r'$$' || d.group(0) == r'\$') return r'$';
        if (d.group(0) == r'$&') return m.group(0) ?? '';
        final index = int.parse(d.group(1)!);
        if (index == 0) return m.group(0) ?? '';
        if (index <= m.groupCount) return m.group(index) ?? '';
        return '';
      },
    );
  }

  /// 单条 replacement 应用：字面规则原样替换，正则规则展开 $N。
  static String _applyReplacement(PurifyRule rule, Match m) =>
      rule.literalReplacement ? rule.replacement : expandCaptures(rule.replacement, m);

  /// 同步净化:仅 Dart 规则(无超时保护,仅用于测试/短文本)
  String purify(String input) {
    var result = input;
    for (final rule in rules) {
      try {
        result = result.replaceAllMapped(
          _compiled(rule),
          // 不能用 Dart 自带的 replacement 模板解析（$1/$& 语义不同且
          // 非法 $ 会抛错），统一走 expandCaptures 自定义展开。
          (m) => _applyReplacement(rule, m),
        );
      } catch (_) {
        // 单条规则异常(如非法正则):跳过,不影响其他规则
      }
    }
    return result;
  }

  /// 异步净化:Dart 规则(独立 Isolate,单条超时保护)+ JS 规则
  /// (引擎不可用时 JS 规则静默跳过)。
  Future<String> purifyAsync(String input) async {
    var result = input;
    for (final rule in rules) {
      if (rule.pattern.isEmpty) continue;
      try {
        result = await _applyDartRule(rule, result);
      } on TimeoutException {
        onRuleTimeout?.call(rule);
      } catch (_) {
        // spawn 失败/规则异常:跳过该条
      }
    }
    if (jsRules.isEmpty) return result;
    try {
      final purifier = JsPurifier(onRuleTimeout: onJsRuleTimeout);
      return await purifier.apply(result, jsRules);
    } catch (_) {
      // 引擎初始化/执行异常:保留 Dart 规则结果,不阻塞阅读
      return result;
    }
  }

  /// 在独立 Isolate 中执行单条 Dart 规则:卡死正则不阻塞主 isolate
  /// 事件循环,超时后立即 kill 该 isolate 并抛 [TimeoutException]。
  ///
  /// 区分"规则慢"与"worker 挂":spawn 失败(worker 起不来)或 worker
  /// 异常退出(onExit 先于结果/超时触发)属基础设施故障 → 降级为主
  /// isolate 同步执行(无超时保护但不误杀);仅 worker 存活却超时才判
  /// 规则慢,触发超时回调。
  static Future<String> _applyDartRule(PurifyRule rule, String input) async {
    final port = ReceivePort();
    final exited = Completer<void>();
    final exitPort = RawReceivePort(exited.complete);
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _purifyIsolateEntry,
        [
          port.sendPort,
          rule.pattern,
          rule.replacement,
          rule.caseSensitive,
          input,
          rule.literalReplacement,
        ],
        onExit: exitPort.sendPort,
      );
    } catch (_) {
      exitPort.close();
      port.close();
      // spawn 失败(资源受限等):同步执行,无超时保护但不误杀
      return _purifySync(rule, input);
    }
    try {
      final message = await port.first.timeout(
        Duration(milliseconds: rule.timeoutMs ?? kPurifyDefaultTimeoutMs),
        onTimeout: () {
          if (exited.isCompleted) {
            // worker 已退出仍未送达结果:基础设施故障(崩溃/被杀),非规则
            // 慢 → 返回 null 走下方同步重试,绝不能误判超时把规则持久禁用
            return null;
          }
          // worker 存活却超时:ReDoS 卡死场景 isolate 无法响应消息,
          // 只能强杀(Isolate.kill 对回溯中的 isolate 生效)
          isolate?.kill(priority: Isolate.immediate);
          throw TimeoutException('净化规则超时: ${rule.pattern}');
        },
      );
      // 消息协议:[ok, result] 列表 —— 入口成功发 [true, result],
      // 编译失败发 [false, null](跳过返回原值,不吃超时);
      // message == null 仅剩一种含义:onTimeout 占位(worker 已死)
      // → 同步重试兜底。
      final packed = message as List<Object?>?;
      if (packed == null) return _purifySync(rule, input);
      if (packed[0] as bool) return packed[1]! as String;
      return input;
    } finally {
      port.close();
      exitPort.close();
    }
  }

  /// 主 isolate 同步执行单条规则(降级路径;编译/执行异常抛给调用方跳过)
  static String _purifySync(PurifyRule rule, String input) {
    return input.replaceAllMapped(
      RegExp(rule.pattern, caseSensitive: rule.caseSensitive),
      (m) => _applyReplacement(rule, m),
    );
  }

  /// Isolate 入口(顶层函数):协议 [ok, result]。
  /// 成功 [true, 替换结果];编译失败 [false, null](调用方跳过规则返回原值)。
  static void _purifyIsolateEntry(List<Object?> args) {
    final sendPort = args[0]! as SendPort;
    try {
      final pattern = args[1]! as String;
      final replacement = args[2]! as String;
      final caseSensitive = args[3]! as bool;
      final input = args[4]! as String;
      final literal = args[5] as bool? ?? false;
      sendPort.send([
        true,
        input.replaceAllMapped(
          RegExp(pattern, caseSensitive: caseSensitive),
          (m) => literal ? replacement : expandCaptures(replacement, m),
        ),
      ]);
    } catch (_) {
      sendPort.send([false, null]);
    }
  }

  static RegExp _compiled(PurifyRule rule) {
    final key = '${rule.caseSensitive ? 1 : 0}:${rule.pattern}';
    if (_regexCache.length >= _regexCacheMax && !_regexCache.containsKey(key)) {
      _regexCache.clear();
    }
    return _regexCache.putIfAbsent(
      key,
      () => RegExp(rule.pattern, caseSensitive: rule.caseSensitive),
    );
  }
}

