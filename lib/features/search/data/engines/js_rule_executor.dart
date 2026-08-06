import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:easy_quickjs/quickjs.dart';
import 'package:html/dom.dart' as dom;
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
/// java.setContent 记录-重放（DOM 切换后查询）：
/// 记录遍注入记录版 java 桥（get/setContent 调用序列 + ajax URL 收集），
/// Dart 重放 doc 流（原 html → 按序 setContent 切换 → get 在对应 doc 查询）
/// 得到提取值表；最终遍注入值表按调用顺序消费。setContent 参数依赖
/// ajax 结果时（第一遍记录为空），真实 ajax 注入后重新记录一遍。
///
/// 能力边界（返回 null 由上层归类）：
/// - eval()/decode()/startBrowser/cookie 动态操作：不支持
/// - java.get 变量参数（依赖运行时计算的选择器）：缓存 miss 返回空
///
/// 记录-重放要求规则**幂等**（Legado 书源规则为纯计算/提取，符合该假设）：
/// 非幂等脚本（x=x+1、数组 push 等副作用累积）在重放时会重复执行导致
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

  /// 当前 manager 中存活的 engine 数（测试断言释放用）
  @visibleForTesting
  static int get liveEngineCount => _manager?.length ?? 0;

  static JsEngineManager? _manager;
  static Future<JsEngineManager?>? _managerInit;
  static int _engineSeq = 0;

  /// 上次初始化失败时间：无引擎平台（如 iOS）5 分钟内不重试，
  /// 避免每次规则执行都触发 5s 超时挂起
  static DateTime? _lastFailTime;

  static Future<JsEngineManager?> _getManager() {
    final failed = _lastFailTime;
    if (failed != null &&
        DateTime.now().difference(failed) < const Duration(minutes: 5)) {
      return Future.value(null);
    }
    // 链式互斥：并发首次调用共享同一初始化 Future，避免双创建泄漏
    final pending = _managerInit;
    if (pending != null) return pending;
    final future = _initManager();
    _managerInit = future;
    return future;
  }

  /// 引擎初始化超时：engineIsolate 启动失败（native 库缺失/平台降级）时
  /// receivePort.first 永不返回，必须限时降级避免搜索挂死
  static const Duration _initTimeout = Duration(seconds: 5);

  static Future<JsEngineManager?> _initManager() async {
    try {
      final m = await JsEngineManager.create().timeout(_initTimeout);
      _manager = m;
      return m;
    } catch (_) {
      // 平台无 quickjs 原生库（如 iOS native assets 不可用）→ 降级；
      // 清除 init 锁，短时缓存失败避免反复超时
      _managerInit = null;
      _lastFailTime = DateTime.now();
      return null;
    }
  }

  /// 回收（强制销毁）：死循环/异常后引擎 isolate 不可复用
  static Future<void> _recycle() async {
    final old = _manager;
    _manager = null;
    _managerInit = null;
    // 异常回收 ≠ 平台无引擎：清除失败缓存，允许立即重建重试
    _lastFailTime = null;
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
    final hasAjax = body.contains('java.ajax');
    final hasSetContent = body.contains('setContent');

    final manager = await _getManager();
    if (manager == null) return null;
    final engine = await manager.createEngine('jsrule${_engineSeq++}');
    var recycled = false;
    try {
      if (!hasSetContent) {
        // 无 setContent：静态预提取 java.get 字面量 + 两遍 ajax
        final cache = _extractLiterals(html, baseUrl ?? '', body);
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
          }
          // 切换为真实 ajax 桥
          await engine.eval(_ajaxRealBridge);
        }

        // 第二遍：执行取最终值
        final result = await engine.eval(body).timeout(evalTimeout);
        final value = result.value.trim();
        return value.isEmpty || value == 'undefined' ? null : value;
      }

      // setContent 路径：记录-重放（见类注释）
      await engine.eval(_recordPrelude(html, baseUrl ?? ''));
      await engine.eval('try { $body } catch (e) {}').timeout(evalTimeout);
      var ops = await _readOps(engine);

      if (hasAjax) {
        final urls = _parseUrls(
            (await engine.eval('JSON.stringify(__ajaxUrls)')).value);
        if (urls.isNotEmpty) {
          final results = await _fetchAll(urls);
          await engine.eval('globalThis.__ajaxCache = ${jsonEncode(results)};');
          // setContent 参数依赖 ajax 结果（第一遍记录为空）时，
          // 用真实结果重新记录一遍（此时 setContent 拿到真实 html）
          final staleSetContent = ops.any(
              (op) => op[0] == 'setContent' && (op[1] as String).isEmpty);
          if (staleSetContent) {
            // 先切换真实 ajax 桥（保留 get/setContent 记录桥），
            // 否则 c=java.ajax(u); setContent(c) 重录仍记录空 html
            await engine.eval(_ajaxRealBridge);
            await engine
                .eval('globalThis.__ops = []; globalThis.__docIndex = 0;');
            await engine.eval('try { $body } catch (e) {}').timeout(evalTimeout);
            ops = await _readOps(engine);
          }
        }
      }

      // Dart 重放 doc 流 → 与记录顺序一致的提取值表 → 注入
      final getValues = _replayGetValues(html, ops);
      await engine.eval('globalThis.__getValues = ${jsonEncode(getValues)};');
      await engine.eval(_finalPrelude);

      // 最终遍：执行取最终值
      final result = await engine.eval(body).timeout(evalTimeout);
      final value = result.value.trim();
      return value.isEmpty || value == 'undefined' ? null : value;
    } on TimeoutException {
      recycled = true;
      await _recycle();
      return null;
    } catch (_) {
      // eval 异常（规则错误/引擎损坏）：回收避免原生断言
      recycled = true;
      await _recycle();
      return null;
    } finally {
      // 正常路径释放 engine（防泄漏）；异常/超时路径 manager 已被
      // forceDispose，engine.dispose 会挂起（无超时响应）→ 跳过
      if (!recycled) {
        try {
          await engine.dispose();
        } catch (_) {}
      }
    }
  }

  /// 读取记录遍的调用序列（['get'|'setContent', 参数..., docIndex]）
  static Future<List<List<dynamic>>> _readOps(JsEngine engine) async {
    final json = (await engine.eval('JSON.stringify(__ops)')).value;
    try {
      return (jsonDecode(json) as List).cast<List<dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Dart 重放 doc 流：原 html → 按序 setContent 切换 → get 在对应 doc
  /// 查询，返回与记录顺序一致的提取值表
  static List<String> _replayGetValues(String html, List<List<dynamic>> ops) {
    final docs = <dom.Document>[parser.parse(html)];
    final values = <String>[];
    for (final op in ops) {
      if (op[0] == 'setContent') {
        docs.add(parser.parse(op[1] as String));
      } else {
        final idx = op[3] as int;
        final doc = idx >= 0 && idx < docs.length ? docs[idx] : docs.last;
        final elements = RuleEngine.queryIn(doc, op[1] as String);
        final value = elements.isEmpty
            ? ''
            : (RuleEngine.valueOf(elements.first, op[2] as String?) ?? '');
        values.add(value);
      }
    }
    return values;
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

  /// 记录模式环境：get/setContent 记录调用序列（docIndex 关联切换后的
  /// 文档），ajax 收集 URL 返回占位。规则执行后由 Dart 重放查询。
  static String _recordPrelude(String html, String baseUrl) {
    return '''
globalThis.result = ${_quote(html)};
globalThis.baseUrl = ${_quote(baseUrl)};
globalThis.__ops = [];
globalThis.__docIndex = 0;
globalThis.__ajaxUrls = [];
globalThis.__ajaxCache = {};
globalThis.java = {
  get: (sel, attr) => {
    if (String(sel) === 'url') return baseUrl;
    __ops.push(['get', String(sel), attr === undefined ? null : String(attr), __docIndex]);
    return '';
  },
  getElement: (sel, attr) => {
    if (String(sel) === 'url') return baseUrl;
    __ops.push(['get', String(sel), attr === undefined ? null : String(attr), __docIndex]);
    return '';
  },
  setContent: (html) => {
    __ops.push(['setContent', String(html)]);
    __docIndex++;
    return '';
  },
  ajax: (url) => { __ajaxUrls.push(String(url)); return ''; }
};
''';
  }

  /// 最终执行环境：get 按记录顺序消费提取值表，setContent 为 no-op
  /// （doc 切换已由 Dart 重放完成），ajax 走真实结果缓存
  static const _finalPrelude = '''
globalThis.__getIdx = 0;
globalThis.java = {
  get: (sel, attr) => {
    if (String(sel) === 'url') return baseUrl;
    const v = __getValues[__getIdx++];
    return v === undefined || v === null ? '' : v;
  },
  getElement: (sel, attr) => {
    if (String(sel) === 'url') return baseUrl;
    const v = __getValues[__getIdx++];
    return v === undefined || v === null ? '' : v;
  },
  setContent: (html) => '',
  ajax: (url) => __ajaxCache[String(url)] || ''
};
''';

  /// 真实 ajax 桥：从预取缓存返回
  static const _ajaxRealBridge = '''
globalThis.java.ajax = (url) => __ajaxCache[String(url)] || '';
''';

  static String _quote(String s) {
    // JSON 字符串转义（含换行/引号），安全注入 JS 字符串字面量
    return jsonEncode(s);
  }
}
