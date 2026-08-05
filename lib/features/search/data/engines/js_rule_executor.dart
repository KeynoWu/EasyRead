import 'dart:async';
import 'dart:convert';
import 'package:easy_quickjs/quickjs.dart';
import 'package:html/parser.dart' as parser;
import 'rule_engine.dart';

/// 完整 JS 规则执行器（阶段 5，基于 quickjs 沙箱引擎）。
///
/// 与阶段 4 模板子集的区分：
/// - [JsTemplateEngine]：同步、无网络、覆盖纯 java.get 链
/// - [JsRuleExecutor]：异步（quickjs isolate）、支持任意字符串处理/
///   正则/变量/条件；java.get 字面量参数预查询注入；java.ajax 预取注入
///
/// 能力边界（返回 null 由上层归类）：
/// - eval()/decode()/startBrowser/cookie 动态操作：不支持
/// - java.setContent 切换文档后依赖新 DOM 的查询：不支持（走模板子集）
/// - java.get 变量参数（依赖运行时计算的选择器）：缓存 miss 返回空
///
/// 安全：引擎在独立 isolate；外部超时（死循环防护）后整体回收；
/// 异常后强制销毁 manager 避免原生断言崩溃。
class JsRuleExecutor {
  /// 单次 eval 超时（死循环防护）
  static const Duration evalTimeout = Duration(seconds: 3);

  static JsEngineManager? _manager;
  static int _engineSeq = 0;

  static Future<JsEngineManager> _getManager() async {
    if (_manager != null) return _manager!;
    final m = await JsEngineManager.create();
    _manager = m;
    return m;
  }

  /// 回收（强制销毁）：死循环/异常后引擎 isolate 不可复用
  static Future<void> _recycle() async {
    final old = _manager;
    _manager = null;
    if (old != null) {
      try {
        await old.forceDispose();
      } catch (_) {}
    }
  }

  /// 执行 JS 规则，返回提取值；不支持/超时/异常返回 null
  static Future<String?> execute(String html, String rawRule, {String? baseUrl}) async {
    final body = _scriptBody(rawRule);
    if (body == null || body.trim().isEmpty) return null;
    if (_unsupported(body)) return null;
    // 含 setContent 的规则由阶段 4 模板子集处理（需 DOM 切换后查询）
    if (body.contains('setContent')) return null;

    // 预提取 java.get 字面量选择器 → Dart 查询 → 注入缓存
    final cache = _extractLiterals(html, body);

    final manager = await _getManager();
    final engine = await manager.createEngine('jsrule${_engineSeq++}');
    try {
      await engine.eval(_prelude(html, baseUrl, cache));
      // 直接执行顶层表达式（函数包裹在 quickjs 1.0.1 下结果序列化异常）
      final result = await engine.eval(body).timeout(evalTimeout);
      final value = result.value.trim();
      return value.isEmpty || value == 'undefined' ? null : value;
    } on TimeoutException {
      await _recycle();
      return null;
    } catch (_) {
      // eval 异常（规则错误/引擎损坏）：回收避免原生断言
      await _recycle();
      return null;
    }
  }

  /// 提取 js 标签包裹体或 at-js 前缀的脚本体
  static String? _scriptBody(String rule) {
    final t = rule.trim();
    if (t.startsWith('<js')) {
      final start = t.indexOf('>');
      final end = t.lastIndexOf('</js>');
      if (start < 0) return null;
      return end > start ? t.substring(start + 1, end) : t.substring(start + 1);
    }
    if (t.startsWith('@js:')) return t.substring(4);
    return null;
  }

  static const _unsupportedMarkers = [
    'eval(',
    'startBrowser',
    'cookie.',
  ];

  static bool _unsupported(String body) => _unsupportedMarkers.any(body.contains);

  /// 预提取 java.get('字面量'[, 'attr']) → (选择器, attr) 列表并查询缓存
  static Map<String, String> _extractLiterals(String html, String body) {
    final cache = <String, String>{};
    final re = RegExp(
        "java\\.(get|getElement)\\(\\s*('([^']*)'|\"([^\"]*)\")(?:,\\s*('([^']*)'|\"([^\"]*)\"))?\\s*\\)");
    for (final m in re.allMatches(body)) {
      final sel = m.group(3) ?? m.group(4) ?? '';
      if (sel.isEmpty) continue;
      final attr = m.group(6) ?? m.group(7);
      if (cache.containsKey('$sel|${attr ?? ''}')) continue;
      final elements = RuleEngine.queryIn(parser.parse(html), sel);
      final value = elements.isEmpty
          ? ''
          : (RuleEngine.valueOf(elements.first, attr) ?? '');
      cache['$sel|${attr ?? ''}'] = value;
    }
    return cache;
  }

  /// 注入执行环境：result/baseUrl + java 桥（从预查询缓存读）
  static String _prelude(String html, String? baseUrl, Map<String, String> cache) {
    final cacheJson = jsonEncode(cache);
    return '''
globalThis.result = ${_quote(html)};
globalThis.baseUrl = ${_quote(baseUrl ?? '')};
globalThis.__javaCache = $cacheJson;
globalThis.java = {
  get: (sel, attr) => __javaCache[sel + '|' + (attr || '')] || '',
  getElement: (sel, attr) => __javaCache[sel + '|' + (attr || '')] || ''
};
''';
  }

  static String _quote(String s) {
    // JSON 字符串转义（含换行/引号），安全注入 JS 字符串字面量
    return jsonEncode(s);
  }
}
