import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:easy_quickjs/quickjs.dart';
import 'package:html/parser.dart' as parser;
import '../../../../core/network/dio_client.dart';
import 'rule_engine.dart';

/// 完整 JS 规则执行器（阶段 5，基于 quickjs 沙箱引擎）。
///
/// 与阶段 4 模板子集的区分：
/// - [JsTemplateEngine]：同步、无网络、覆盖纯 java.get 链
/// - [JsRuleExecutor]：异步（quickjs isolate）、支持任意字符串处理/
///   正则/变量/条件；java.get 字面量参数预查询注入；java.ajax 两遍执行
///
/// java.ajax 两遍执行：
/// 第一遍注入记录版 ajax（收集 URL），执行后 Dart 并发请求并注入结果；
/// 第二遍用真实结果重执行取最终值（Legado 规则为纯计算，幂等可重放）。
///
/// 能力边界（返回 null 由上层归类）：
/// - eval()/decode()/startBrowser/cookie 动态操作：不支持
/// - java.setContent 切换文档后依赖新 DOM 的查询：不支持（走模板子集）
/// - java.get 变量参数（依赖运行时计算的选择器）：缓存 miss 返回空
///
/// 两遍执行要求规则**幂等**（Legado 书源规则为纯计算/提取，符合该假设）：
/// 非幂等脚本（x=x+1、数组 push 等副作用累积）在第二遍会重复执行导致
/// 结果错误，此类规则不在支持范围。管理状态 [_manager] 为进程级单例，
/// 死循环/异常触发 [_recycle] 强制销毁后会重建（后续执行多一次初始化
/// 开销，不产生额外失败）。
///
/// 安全：引擎在独立 isolate；外部超时（死循环防护）后整体回收；
/// 异常后强制销毁 manager 避免原生断言崩溃。ajax 请求走 DioClient
/// （SSRF 校验/重定向安全/限频）。
class JsRuleExecutor {
  /// 单次 eval 超时（死循环防护）
  static const Duration evalTimeout = Duration(seconds: 3);

  /// 单次 ajax 请求超时
  static const Duration ajaxTimeout = Duration(seconds: 8);

  /// 可注入的请求实现（测试用）；null 时走 DioClient
  @visibleForTesting
  static Future<String> Function(String url)? fetcher;

  static JsEngineManager? _manager;
  static int _engineSeq = 0;

  static Future<JsEngineManager?> _getManager() async {
    if (_manager != null) return _manager!;
    try {
      final m = await JsEngineManager.create();
      _manager = m;
      return m;
    } catch (_) {
      // 平台无 quickjs 原生库（如 iOS native assets 不可用）→ 降级
      return null;
    }
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
    final cache = _extractLiterals(html, baseUrl ?? '', body);
    final hasAjax = body.contains('java.ajax');

    final manager = await _getManager();
    if (manager == null) return null;
    final engine = await manager.createEngine('jsrule${_engineSeq++}');
    try {
      await engine.eval(_prelude(html, baseUrl ?? '', cache));

      if (hasAjax) {
        // 第一遍：执行收集 ajax URL（占位 ajax 返回空可能引发 JS 异常，
        // 用 try-catch 包裹——ajax 调用在异常前已记录 URL）
        await engine
            .eval('try { $body } catch (e) {}')
            .timeout(evalTimeout);
        final urls = _parseUrls(
            (await engine.eval('JSON.stringify(__ajaxUrls)')).value);
        if (urls.isNotEmpty) {
          final results = await _fetchAll(urls);
          await engine.eval(
              'globalThis.__ajaxCache = ${jsonEncode(results)};');
          // 切换为真实 ajax 桥
          await engine.eval(_ajaxRealBridge);
        } else {
          await engine.eval(_ajaxRealBridge);
        }
      }

      // 第二遍：执行取最终值
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

  /// 解析 JSON 数组 URL 列表
  static List<String> _parseUrls(String json) {
    try {
      final list = jsonDecode(json) as List;
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  /// 并发请求所有 ajax URL（走 DioClient 或注入 fetcher）
  static Future<Map<String, String>> _fetchAll(List<String> urls) async {
    final results = <String, String>{};
    final client = DioClient();
    await Future.wait(urls.map((url) async {
      try {
        final html = fetcher != null
            ? await fetcher!(url).timeout(ajaxTimeout)
            : await client.getString(url).timeout(ajaxTimeout);
        results[url] = html;
      } catch (_) {
        results[url] = '';
      }
    }));
    return results;
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

  /// 预提取 java.get('字面量'[, 'attr']) → 查询缓存。
  /// 特殊键 'url'（Legado 取当前页 URL）返回 baseUrl。
  static Map<String, String> _extractLiterals(
      String html, String baseUrl, String body) {
    final cache = <String, String>{};
    final re = RegExp(
        "java\\.(get|getElement)\\(\\s*('([^']*)'|\"([^\"]*)\")(?:,\\s*('([^']*)'|\"([^\"]*)\"))?\\s*\\)");
    for (final m in re.allMatches(body)) {
      final sel = m.group(3) ?? m.group(4) ?? '';
      if (sel.isEmpty) continue;
      final attr = m.group(6) ?? m.group(7);
      final key = '$sel|${attr ?? ''}';
      if (cache.containsKey(key)) continue;
      if (sel == 'url') {
        // Legado 特殊语义：当前页 URL
        cache[key] = baseUrl;
        continue;
      }
      final elements = RuleEngine.queryIn(parser.parse(html), sel);
      final value = elements.isEmpty
          ? ''
          : (RuleEngine.valueOf(elements.first, attr) ?? '');
      cache[key] = value;
    }
    return cache;
  }

  /// 注入执行环境：result/baseUrl + java 桥（预查询缓存 + 记录版 ajax）
  static String _prelude(String html, String baseUrl, Map<String, String> cache) {
    final cacheJson = jsonEncode(cache);
    return '''
globalThis.result = ${_quote(html)};
globalThis.baseUrl = ${_quote(baseUrl)};
globalThis.__javaCache = $cacheJson;
globalThis.__ajaxUrls = [];
globalThis.__ajaxCache = {};
globalThis.java = {
  get: (sel, attr) => __javaCache[sel + '|' + (attr || '')] || '',
  getElement: (sel, attr) => __javaCache[sel + '|' + (attr || '')] || '',
  ajax: (url) => { __ajaxUrls.push(String(url)); return ''; }
};
''';
  }

  /// 真实 ajax 桥：从预取缓存返回
  static const _ajaxRealBridge = '''
globalThis.java.ajax = (url) => __ajaxCache[String(url)] || '';
''';

  static String _quote(String s) {
    // JSON 字符串转义（含换行/引号），安全注入 JS 字符串字面量
    return jsonEncode(s);
  }
}
