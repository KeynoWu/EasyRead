import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:easy_quickjs/quickjs.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import '../../../../core/network/dio_client.dart';
import 'js_network.dart';
import '../../../settings/domain/entities/chinese_conversion.dart';
import 'json_path.dart';
import 'js_crypto.dart';
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

  @visibleForTesting
  static DioClient? networkClient;

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
      debugPrint('[quickjs] 引擎初始化成功，平台 JS 规则可用');
      return m;
    } catch (e) {
      // 平台无 quickjs 原生库（如 iOS native assets 不可用）→ 降级；
      // 清除 init 锁，短时缓存失败避免反复超时
      _managerInit = null;
      _lastFailTime = DateTime.now();
      debugPrint('[quickjs] 引擎初始化失败（5 分钟内降级）: $e');
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
  static Future<String?> execute(
    String html,
    String rawRule, {
    String? baseUrl,
    String? charset,
    Map<String, String>? variables,
    Map<String, String>? cookies,
  }) async {
    final body = _scriptBody(rawRule);
    if (body == null || body.trim().isEmpty) return null;
    if (_unsupported(body)) return null;
    final hasAjax = body.contains('java.ajax');
    final hasPost = body.contains('java.post');
    final hasHead = body.contains('java.head');
    final hasSetContent = body.contains('setContent');
    final hasGetElements = body.contains('java.getElements');
    final hasCrypto = _hasCryptoBridge(body);

    final manager = await _getManager();
    if (manager == null) return null;
    final engine = await manager.createEngine('jsrule${_engineSeq++}');
    var recycled = false;
    try {
      if (!hasSetContent && !hasGetElements) {
        // 无 setContent：静态预提取 java.get 字面量 + 两遍 ajax
        final cache = _extractLiterals(html, baseUrl ?? '', body);
        final getStringCache = _extractGetStringCache(html, body);
        final getStringListCache = _extractGetStringListCache(html, body);
        await engine
            .eval(
              _prelude(
                html,
                baseUrl ?? '',
                cache,
                getStringCache: getStringCache,
                getStringListCache: getStringListCache,
                cookies: cookies,
              ),
            )
            .timeout(evalTimeout);

        if (hasAjax || hasCrypto || hasPost || hasHead) {
          // 第一遍：执行收集 ajax URL（占位 ajax 返回空可能引发 JS 异常，
          // 用 try-catch 包裹——ajax 调用在异常前已记录 URL）
          await engine.eval('try { $body } catch (e) {}').timeout(evalTimeout);
          if (hasAjax) {
            final urls = _parseUrls(
              (await engine
                      .eval('JSON.stringify(__ajaxUrls)')
                      .timeout(evalTimeout))
                  .value,
            );
            if (urls.isNotEmpty) {
              final results = await JsNetwork.fetchAll(
                urls,
                baseUrl: baseUrl ?? '',
                charset: charset,
              );
              await engine
                  .eval('globalThis.__ajaxCache = ${jsonEncode(results)};')
                  .timeout(evalTimeout);
            }
            // 切换为真实 ajax 桥
            await engine.eval(_ajaxRealBridge).timeout(evalTimeout);
          }
          if (hasPost || hasHead) {
            final networkOps = await JsNetwork.readNetworkOps(engine);
            if (networkOps.isNotEmpty) {
              final results = await JsNetwork.fetchNetworkResults(
                networkOps,
                baseUrl: baseUrl ?? '',
                charset: charset,
              );
              await engine
                  .eval(
                    'globalThis.__postCache = ${jsonEncode(results)};'
                    'globalThis.__headCache = ${jsonEncode(results)};',
                  )
                  .timeout(evalTimeout);
            }
            await engine.eval(_networkRealBridge).timeout(evalTimeout);
          }
        }

        if (hasCrypto) {
          final crypto = await _JsCryptoCaches.fromEngine(engine);
          await engine.eval(crypto.realBridge).timeout(evalTimeout);
        }

        // 第二遍：执行取最终值
        final result = await engine.eval(body).timeout(evalTimeout);
        final value = result.value.trim();
        await _mergePutMap(engine, variables);
        await _mergeCookies(engine, cookies);
        return value.isEmpty || value == 'undefined' ? null : value;
      }

      // setContent 路径：记录-重放（见类注释）
      await engine
          .eval(
            _recordPrelude(
              html,
              baseUrl ?? '',
              getStringCache: _extractGetStringCache(html, body),
              getStringListCache: _extractGetStringListCache(html, body),
              cookies: cookies,
            ),
          )
          .timeout(evalTimeout);
      await engine.eval('try { $body } catch (e) {}').timeout(evalTimeout);
      var ops = await _readOps(engine);

      if (hasAjax || hasPost || hasHead) {
        if (hasAjax) {
          final urls = _parseUrls(
            (await engine
                    .eval('JSON.stringify(__ajaxUrls)')
                    .timeout(evalTimeout))
                .value,
          );
          if (urls.isNotEmpty) {
            final results = await JsNetwork.fetchAll(
              urls,
              baseUrl: baseUrl ?? '',
              charset: charset,
            );
            await engine
                .eval('globalThis.__ajaxCache = ${jsonEncode(results)};')
                .timeout(evalTimeout);
          }
          await engine.eval(_ajaxRealBridge).timeout(evalTimeout);
        }
        if (hasPost || hasHead) {
          final networkOps = await JsNetwork.readNetworkOps(engine);
          if (networkOps.isNotEmpty) {
            final results = await JsNetwork.fetchNetworkResults(
              networkOps,
              baseUrl: baseUrl ?? '',
              charset: charset,
            );
            await engine
                .eval(
                  'globalThis.__postCache = ${jsonEncode(results)};'
                  'globalThis.__headCache = ${jsonEncode(results)};',
                )
                .timeout(evalTimeout);
          }
          await engine.eval(_networkRealBridge).timeout(evalTimeout);
        }
        // setContent 参数依赖 ajax/post 结果（第一遍记录为空）时，
        // 用真实结果重新记录一遍（此时 setContent 拿到真实 html）
        final staleSetContent = ops.any(
          (op) => op[0] == 'setContent' && (op[1] as String).isEmpty,
        );
        if (staleSetContent) {
          // 先切换真实网络桥（保留 get/setContent 记录桥），
          // 否则 c=java.ajax(u); setContent(c) 重录仍记录空 html
          await engine.eval(
            'globalThis.__ops = []; globalThis.__docIndex = 0;',
          );
          await engine.eval('try { $body } catch (e) {}').timeout(evalTimeout);
          ops = await _readOps(engine);
        }
      }

      // Dart 重放 doc 流 → 与记录顺序一致的提取值表/元素快照 → 注入
      final replay = _replayOps(html, ops);
      final getValues = replay.getValues;
      await engine
          .eval('globalThis.__getValues = ${jsonEncode(getValues)};')
          .timeout(evalTimeout);
      await engine
          .eval(
            'globalThis.__elementCaches = ${jsonEncode(replay.elementCaches)};'
            'globalThis.__getElementsIdx = 0;',
          )
          .timeout(evalTimeout);
      await engine.eval(_finalPrelude).timeout(evalTimeout);
      await engine.eval(_networkRealBridge).timeout(evalTimeout);
      await engine
          .eval(_cookieBridge(cookies ?? const {}, seed: false))
          .timeout(evalTimeout);
      if (hasCrypto) {
        final crypto = await _JsCryptoCaches.fromEngine(engine);
        await engine.eval(crypto.realBridge).timeout(evalTimeout);
      }

      // 最终遍：执行取最终值
      final result = await engine.eval(body).timeout(evalTimeout);
      final value = result.value.trim();
      await _mergePutMap(engine, variables);
      await _mergeCookies(engine, cookies);
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

  /// 执行 ruleToc.formatJs / ruleToc.isVolume 的 item 作用域 JS。
  ///
  /// legado 语义：脚本内 `item` 变量为 {title, url}，脚本可修改后返回
  /// item（或返回新对象/布尔值）。兼容两种写法：
  /// 1. 函数/return 风格：`item.title = ...; return item;`、IIFE、
  ///    `item.title = ...; item`（修改 item 后以其结尾）——函数包裹执行，
  ///    完成值取最终 item 序列化结果（脚本返回 undefined/null 时取 item）。
  /// 2. 裸表达式风格：`item.title.includes('卷')` 等直接以表达式结果为值
  ///    ——第一遍结果等于原 item（脚本未修改/未返回）时，再按裸表达式
  ///    求值取完成值。
  /// 失败/无引擎/超时返回 null，由调用方按原值兜底（iOS 降级一致）。
  static Future<String?> evalItemScript(
    String rawRule,
    Map<String, String> item, {
    String? baseUrl,
    String? charset,
  }) async {
    final body = _scriptBody(rawRule);
    if (body == null || body.trim().isEmpty) return null;
    // 第一遍：函数包裹（支持顶层 return / IIFE / 语句序列以 item 结尾）
    final functionWrapped =
        '<js>'
        'var item = JSON.parse(result);\n'
        'var __ret = (function () {\n$body\n})();\n'
        'var __out = (__ret === undefined || __ret === null) ? item : __ret;\n'
        'JSON.stringify(__out);'
        '</js>';
    final first = await execute(
      jsonEncode(item),
      functionWrapped,
      baseUrl: baseUrl,
      charset: charset,
    );
    // 执行失败/无引擎：直接失败，不重复执行
    if (first == null) return null;
    // 脚本有实际返回或修改（结果不再是原 item）→ 直接采用
    if (!_isOriginalItemJson(first, item)) return first;
    // 裸表达式风格：以规则体完成值作为结果
    final bareWrapped =
        '<js>'
        'var item = JSON.parse(result);\n'
        'JSON.stringify($body);'
        '</js>';
    final second = await execute(
      jsonEncode(item),
      bareWrapped,
      baseUrl: baseUrl,
      charset: charset,
    );
    return second ?? first;
  }

  /// 判断 JS 结果是否仍等于原 item（脚本未修改/未返回时的兜底结果）。
  static bool _isOriginalItemJson(String value, Map<String, String> item) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return false;
      return jsonEncode(decoded) == jsonEncode(item);
    } catch (_) {
      return false;
    }
  }

  /// 读取记录遍的调用序列（['get'|'setContent', 参数..., docIndex]）
  static Future<List<List<dynamic>>> _readOps(JsEngine engine) async {
    final json =
        (await engine.eval('JSON.stringify(__ops)').timeout(evalTimeout)).value;
    try {
      return (jsonDecode(json) as List).cast<List<dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Dart 重放 doc 流：原 html → 按序 setContent 切换 → get/getElements 在
  /// 对应 doc 查询，返回与记录顺序一致的提取值表和元素快照
  static ({
    List<String> getValues,
    Map<String, List<Map<String, dynamic>>> elementCaches,
  })
  _replayOps(String html, List<List<dynamic>> ops) {
    final docs = <dom.Document>[parser.parse(html)];
    final values = <String>[];
    final elementCaches = <String, List<Map<String, dynamic>>>{};
    var elementCallIndex = 0;
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      if (op[0] == 'setContent') {
        docs.add(parser.parse(op[1] as String));
      } else if (op[0] == 'getElements') {
        final idx = op[3] as int;
        final doc = idx >= 0 && idx < docs.length ? docs[idx] : docs.last;
        final elements = RuleEngine.queryIn(doc, op[1] as String);
        elementCaches['${elementCallIndex++}'] = [
          for (final element in elements) _elementSnapshot(element),
        ];
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
    return (getValues: values, elementCaches: elementCaches);
  }

  static Map<String, dynamic> _elementSnapshot(dom.Element element) {
    return {
      'html': element.outerHtml,
      'text': RuleEngine.valueOf(element, 'text') ?? '',
      'ownText': RuleEngine.valueOf(element, 'ownText') ?? '',
      'attrs': Map<String, String>.from(element.attributes),
    };
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
  /// 并发上限 [JsNetwork.maxConcurrentFetches]，避免恶意/异常规则一次性发起
  /// 大量请求拖垮内存与网络。






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
    'setTimeout',
    '_ffi',
  ];

  /// 黑名单命中：除直接匹配外，还剥离引号/空白后防字符串拼接绕过
  /// （如 'ev'+'al('、'_'+'ffi'+'Notify'）。仍是纵深防御一层——
  /// QuickJS 侧无 registerBridge、默认不绑定定时器，逃逸面已收窄。
  static bool _unsupported(String body) {
    if (_unsupportedMarkers.any(body.contains)) return true;
    // 剥离空白/引号/加号/点号等符号后再检查，防 'ev'+'al('、
    // '_ffi'+'Notify' 之类字符串拼接绕过（仍是纵深防御一层，
    // QuickJS 侧无 registerBridge、默认不绑定定时器，逃逸面已收窄）。
    final normalized = body.replaceAll(RegExp(r'[^A-Za-z0-9_()]'), '');
    return normalized.contains('_ffiNotify') ||
        normalized.contains('eval(') ||
        normalized.contains('startBrowser') ||
        normalized.contains('setTimeout');
  }

  static final _templateExprPattern = RegExp(r'\{\{\s*(java\.[^{}]+?)\s*\}\}');

  /// 执行 URL/字段模板中的 `{{java.*}}` 表达式，其他 `{{}}` 保留给
  /// [RuleTemplate]。支持 java.getString/get、md5Encode、base64Encode、
  /// timeFormat/timeFormatUTC。返回插值后的模板；无引擎时原样返回。
  static Future<String?> evalTemplate(
    String template, {
    Map<String, dynamic>? json,
    String? html,
    int? page,
    String? baseUrl,
    String? charset,
  }) async {
    final matches = _templateExprPattern.allMatches(template).toList();
    if (matches.isEmpty) return template;
    final expressions = [for (final match in matches) match.group(1)!.trim()];
    final body = 'JSON.stringify([${expressions.join(',')}])';

    final manager = await _getManager();
    if (manager == null) return template;
    final engine = await manager.createEngine('jstemplate${_engineSeq++}');
    var recycled = false;
    try {
      final recordPrelude = _templateRecordPrelude(
        json ?? const {},
        html ?? '',
        baseUrl ?? '',
        page,
      );
      await engine.eval(recordPrelude).timeout(evalTimeout);
      await engine
          .eval('try { $body } catch (e) { "[]" }')
          .timeout(evalTimeout);

      var caches = await _readTemplateCaches(engine, json, html);
      for (var round = 0; round < 4; round++) {
        await engine
            .eval(
              _templateRealPrelude(
                caches.jsonCache,
                caches.htmlCache,
                caches.md5Cache,
                caches.base64Cache,
                caches.base64DecodeCache,
                caches.base64DecodeByteCache,
                caches.hmacCache,
                caches.hmacBase64Cache,
                caches.aesCache,
                caches.aesBase64Cache,
                caches.aesEncodeBase64Cache,
                caches.hexEncodeCache,
                caches.hexDecodeCache,
                caches.uriCache,
                caches.t2sCache,
                caches.s2tCache,
                caches.uuidCache,
                caches.putCache,
                caches.timeCache,
                collect: true,
              ),
            )
            .timeout(evalTimeout);
        await engine
            .eval('try { $body } catch (e) { "[]" }')
            .timeout(evalTimeout);
        final next = await _readTemplateCaches(engine, json, html);
        if (next.argCount == caches.argCount) {
          caches = next;
          break;
        }
        caches = next;
      }
      await engine
          .eval(
            _templateRealPrelude(
              caches.jsonCache,
              caches.htmlCache,
              caches.md5Cache,
              caches.base64Cache,
              caches.base64DecodeCache,
              caches.base64DecodeByteCache,
              caches.hmacCache,
              caches.hmacBase64Cache,
              caches.aesCache,
              caches.aesBase64Cache,
              caches.aesEncodeBase64Cache,
              caches.hexEncodeCache,
              caches.hexDecodeCache,
              caches.uriCache,
              caches.t2sCache,
              caches.s2tCache,
              caches.uuidCache,
              caches.putCache,
              caches.timeCache,
            ),
          )
          .timeout(evalTimeout);

      final result = await engine.eval(body).timeout(evalTimeout);
      final decoded = jsonDecode(result.value);
      if (decoded is! List || decoded.length != matches.length) {
        return template;
      }
      final buffer = StringBuffer();
      var cursor = 0;
      for (var i = 0; i < matches.length; i++) {
        final match = matches[i];
        buffer.write(template.substring(cursor, match.start));
        buffer.write(decoded[i]?.toString() ?? '');
        cursor = match.end;
      }
      buffer.write(template.substring(cursor));
      return buffer.toString();
    } on TimeoutException {
      recycled = true;
      await _recycle();
      return template;
    } catch (_) {
      recycled = true;
      await _recycle();
      return template;
    } finally {
      if (!recycled) {
        try {
          await engine.dispose();
        } catch (_) {}
      }
    }
  }

  static String _templateRecordPrelude(
    Map<String, dynamic> json,
    String html,
    String baseUrl,
    int? page,
  ) {
    return '''
globalThis.result = ${_quote(html)};
globalThis.baseUrl = ${_quote(baseUrl)};
globalThis.page = ${page ?? 'undefined'};
globalThis.__jsonPaths = [];
globalThis.__htmlPaths = [];
globalThis.__md5 = [];
globalThis.__base64 = [];
globalThis.__base64Decode = [];
globalThis.__base64DecodeByte = [];
globalThis.__hmac = [];
globalThis.__hmacBase64 = [];
globalThis.__digestHex = [];
globalThis.__aesDecode = [];
globalThis.__aesBase64Decode = [];
globalThis.__aesEncodeBase64 = [];
globalThis.__hexEncode = [];
globalThis.__hexDecode = [];
globalThis.__uri = [];
globalThis.__t2s = [];
globalThis.__s2t = [];
globalThis.__s2t = [];
globalThis.__uuidCount = 0;
globalThis.__putMap = {};
globalThis.__time = [];
globalThis.java = {
  put: (key, value) => { __putMap[String(key)] = String(value); return ''; },
  getString: (path) => {
    if (__putMap.hasOwnProperty(String(path))) return __putMap[String(path)];
    __jsonPaths.push(String(path)); return '';
  },
  get: (path) => {
    if (__putMap.hasOwnProperty(String(path))) return __putMap[String(path)];
    __htmlPaths.push(String(path)); return '';
  },
  getElement: (path) => {
    if (__putMap.hasOwnProperty(String(path))) return __putMap[String(path)];
    __htmlPaths.push(String(path)); return '';
  },
  md5Encode: (str) => { __md5.push(String(str)); return ''; },
  base64Encode: (str) => { __base64.push(String(str)); return ''; },
  base64Decode: (str) => { __base64Decode.push(String(str)); return ''; },
  base64DecodeToByteArray: (str) => { __base64DecodeByte.push(String(str)); return []; },
  HMacHex: (data, algorithm, key) => { __hmac.push([String(data), String(algorithm), String(key)]); return ''; },
  HMacBase64: (data, algorithm, key) => { __hmacBase64.push([String(data), String(algorithm), String(key)]); return ''; },
  aesDecodeToString: (data, key, transformation, iv) => { __aesDecode.push([String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return ''; },
  aesBase64DecodeToString: (data, key, transformation, iv) => { __aesBase64Decode.push([String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return ''; },
  aesEncodeToBase64String: (data, key, transformation, iv) => { __aesEncodeBase64.push([String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return ''; },
  hexEncodeToString: (str) => { __hexEncode.push(String(str)); return ''; },
  hexDecodeToString: (hex) => { __hexDecode.push(String(hex)); return ''; },
  encodeURI: (str) => { __uri.push(String(str)); return ''; },
  t2s: (str) => { __t2s.push(String(str)); return ''; },
  s2t: (str) => { __s2t.push(String(str)); return ''; },
  randomUUID: () => { __uuidCount++; return ''; },
  log: () => '',
  toast: () => '',
  longToast: () => '',
  timeFormat: (time, format) => { __time.push([String(time), format || '', 0]); return ''; },
  timeFormatUTC: (time, format, shift) => { __time.push([String(time), format || '', shift || 0]); return ''; }
};
''';
  }

  static String _templateRealPrelude(
    Map<String, String> jsonCache,
    Map<String, String> htmlCache,
    Map<String, String> md5Cache,
    Map<String, String> base64Cache,
    Map<String, String> base64DecodeCache,
    Map<String, String> base64DecodeByteCache,
    Map<String, String> hmacCache,
    Map<String, String> hmacBase64Cache,
    Map<String, String> aesCache,
    Map<String, String> aesBase64Cache,
    Map<String, String> aesEncodeBase64Cache,
    Map<String, String> hexEncodeCache,
    Map<String, String> hexDecodeCache,
    Map<String, String> uriCache,
    Map<String, String> t2sCache,
    Map<String, String> s2tCache,
    List<String> uuidCache,
    Map<String, String> putCache,
    Map<String, String> timeCache, {
    bool collect = false,
  }) {
    return '''
globalThis.__collect = $collect;
globalThis.rec = (arr, value) => { if (__collect) arr.push(value); };
globalThis.__jsonCache = ${jsonEncode(jsonCache)};
globalThis.__htmlCache = ${jsonEncode(htmlCache)};
globalThis.__md5Cache = ${jsonEncode(md5Cache)};
globalThis.__base64Cache = ${jsonEncode(base64Cache)};
globalThis.__base64DecodeCache = ${jsonEncode(base64DecodeCache)};
globalThis.__base64DecodeByteCache = ${jsonEncode(base64DecodeByteCache)};
globalThis.__hmacCache = ${jsonEncode(hmacCache)};
globalThis.__hmacBase64Cache = ${jsonEncode(hmacBase64Cache)};
globalThis.__aesCache = ${jsonEncode(aesCache)};
globalThis.__aesBase64Cache = ${jsonEncode(aesBase64Cache)};
globalThis.__aesEncodeBase64Cache = ${jsonEncode(aesEncodeBase64Cache)};
globalThis.__hexEncodeCache = ${jsonEncode(hexEncodeCache)};
globalThis.__hexDecodeCache = ${jsonEncode(hexDecodeCache)};
globalThis.__uriCache = ${jsonEncode(uriCache)};
globalThis.__t2sCache = ${jsonEncode(t2sCache)};
globalThis.__s2tCache = ${jsonEncode(s2tCache)};
globalThis.__s2tCache = ${jsonEncode(s2tCache)};
globalThis.__uuidCache = ${jsonEncode(uuidCache)};
globalThis.__uuidIdx = 0;
globalThis.__putCache = ${jsonEncode(putCache)};
globalThis.__timeCache = ${jsonEncode(timeCache)};
globalThis.java = {
  put: (key, value) => { if (__collect) __putMap[String(key)] = String(value); __putCache[String(key)] = String(value); return ''; },
  getString: (path) => { rec(__jsonPaths, String(path)); return __putCache[String(path)] || __jsonCache[String(path)] || ''; },
  get: (path) => { rec(__htmlPaths, String(path)); return __putCache[String(path)] || __htmlCache[String(path)] || ''; },
  getElement: (path) => { rec(__htmlPaths, String(path)); return __putCache[String(path)] || __htmlCache[String(path)] || ''; },
  md5Encode: (str) => { rec(__md5, String(str)); return __md5Cache[String(str)] || ''; },
  base64Encode: (str) => { rec(__base64, String(str)); return __base64Cache[String(str)] || ''; },
  base64Decode: (str) => { rec(__base64Decode, String(str)); return __base64DecodeCache[String(str)] || ''; },
  base64DecodeToByteArray: (str) => { rec(__base64DecodeByte, String(str)); return __base64DecodeByteCache[String(str)] ? JSON.parse(__base64DecodeByteCache[String(str)]) : []; },
  HMacHex: (data, algorithm, key) => { rec(__hmac, [String(data), String(algorithm), String(key)]); return __hmacCache[String(data) + '|' + String(algorithm) + '|' + String(key)] || ''; },
  HMacBase64: (data, algorithm, key) => { rec(__hmacBase64, [String(data), String(algorithm), String(key)]); return __hmacBase64Cache[String(data) + '|' + String(algorithm) + '|' + String(key)] || ''; },
  aesDecodeToString: (data, key, transformation, iv) => { rec(__aesDecode, [String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return __aesCache[String(data) + '|' + String(key) + '|' + String(transformation) + '|' + (iv === undefined || iv === null ? '' : String(iv))] || ''; },
  aesBase64DecodeToString: (data, key, transformation, iv) => { rec(__aesBase64Decode, [String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return __aesBase64Cache[String(data) + '|' + String(key) + '|' + String(transformation) + '|' + (iv === undefined || iv === null ? '' : String(iv))] || ''; },
  aesEncodeToBase64String: (data, key, transformation, iv) => { rec(__aesEncodeBase64, [String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return __aesEncodeBase64Cache[String(data) + '|' + String(key) + '|' + String(transformation) + '|' + (iv === undefined || iv === null ? '' : String(iv))] || ''; },
  hexEncodeToString: (str) => { rec(__hexEncode, String(str)); return __hexEncodeCache[String(str)] || ''; },
  hexDecodeToString: (hex) => { rec(__hexDecode, String(hex)); return __hexDecodeCache[String(hex)] || ''; },
  encodeURI: (str) => { rec(__uri, String(str)); return __uriCache[String(str)] || ''; },
  t2s: (str) => { rec(__t2s, String(str)); return __t2sCache[String(str)] || ''; },
  s2t: (str) => { rec(__s2t, String(str)); return __s2tCache[String(str)] || ''; },
  randomUUID: () => __uuidCache[__uuidIdx++] || '',
  log: () => '',
  toast: () => '',
  longToast: () => '',
  timeFormat: (time, format) => { rec(__time, [String(time), format || '', 0]); return __timeCache[String(time) + '|' + (format || '') + '|0'] || ''; },
  timeFormatUTC: (time, format, shift) => { rec(__time, [String(time), format || '', shift || 0]); return __timeCache[String(time) + '|' + (format || '') + '|' + (shift || 0)] || ''; }
};
''';
  }

  static Future<_TemplateCaches> _readTemplateCaches(
    JsEngine engine,
    Map<String, dynamic>? json,
    String? html,
  ) async {
    final jsonPaths = await _readStringList(engine, '__jsonPaths');
    final htmlPaths = await _readStringList(engine, '__htmlPaths');
    final t2sArgs = await _readStringList(engine, '__t2s');
    final s2tArgs = await _readStringList(engine, '__s2t');
    final uuidCount = await _readInt(engine, '__uuidCount');
    final md5Args = await _readStringList(engine, '__md5');
    final base64Args = await _readStringList(engine, '__base64');
    final base64DecodeArgs = await _readStringList(engine, '__base64Decode');
    final base64DecodeByteArgs = await _readStringList(
      engine,
      '__base64DecodeByte',
    );
    final hmacArgs = await JsCrypto.readHmacArgs(engine, '__hmac');
    final hmacBase64Args = await JsCrypto.readHmacArgs(engine, '__hmacBase64');
    final aesArgs = await JsCrypto.readAesArgs(engine, '__aesDecode');
    final aesBase64Args = await JsCrypto.readAesArgs(engine, '__aesBase64Decode');
    final aesEncodeBase64Args = await JsCrypto.readAesArgs(engine, '__aesEncodeBase64');
    final hexEncodeArgs = await _readStringList(engine, '__hexEncode');
    final hexDecodeArgs = await _readStringList(engine, '__hexDecode');
    final uriArgs = await _readStringList(engine, '__uri');
    final timeArgs = await JsCrypto.readTimeArgs(engine);
    final caches = _TemplateCaches(
      jsonCache: {
        for (final path in jsonPaths) path: JsCrypto.queryJsonPath(json, path),
      },
      htmlCache: {
        for (final path in htmlPaths) path: JsCrypto.queryHtmlPath(html ?? '', path),
      },
      md5Cache: {
        for (final arg in md5Args)
          arg: md5.convert(utf8.encode(arg)).toString(),
      },
      base64Cache: {
        for (final arg in base64Args) arg: base64Encode(utf8.encode(arg)),
      },
      base64DecodeCache: {
        for (final arg in base64DecodeArgs) arg: JsCrypto.base64DecodeToString(arg),
      },
      base64DecodeByteCache: {
        for (final arg in base64DecodeByteArgs)
          arg: jsonEncode(JsCrypto.base64DecodeToBytes(arg)),
      },
      hmacCache: {for (final arg in hmacArgs) arg.cacheKey: JsCrypto.hmacHex(arg)},
      hmacBase64Cache: {
        for (final arg in hmacBase64Args) arg.cacheKey: JsCrypto.hmacBase64(arg),
      },
      aesCache: {
        for (final arg in aesArgs)
          arg.cacheKey: JsCrypto.aesDecodeToString(arg, base64Input: false),
      },
      aesBase64Cache: {
        for (final arg in aesBase64Args)
          arg.cacheKey: JsCrypto.aesDecodeToString(arg, base64Input: true),
      },
      aesEncodeBase64Cache: {
        for (final arg in aesEncodeBase64Args)
          arg.cacheKey: JsCrypto.aesEncodeToBase64(arg),
      },
      hexEncodeCache: {for (final arg in hexEncodeArgs) arg: JsCrypto.hexEncode(arg)},
      hexDecodeCache: {for (final arg in hexDecodeArgs) arg: JsCrypto.hexDecode(arg)},
      uriCache: {
        for (final arg in uriArgs)
          arg: Uri.encodeComponent(arg).replaceAll('%20', '+'),
      },
      t2sCache: {
        for (final arg in t2sArgs)
          arg: ChineseConversion.convert(arg, ChineseConversionMode.simplified),
      },
      s2tCache: {
        for (final arg in s2tArgs)
          arg: ChineseConversion.convert(
            arg,
            ChineseConversionMode.traditional,
          ),
      },
      uuidCache: List.generate(uuidCount, (_) => JsCrypto.uuid4()),
      putCache: await _readPutMap(engine),
      timeCache: {for (final arg in timeArgs) arg.key: JsCrypto.formatTimestamp(arg)},
    );
    return caches;
  }

  static Future<List<String>> _readStringList(
    JsEngine engine,
    String name,
  ) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify($name)').timeout(evalTimeout)).value,
      );
      return (decoded as List).map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<int> _readInt(JsEngine engine, String name) async {
    try {
      return int.tryParse(
            (await engine.eval('JSON.stringify($name)').timeout(evalTimeout))
                .value,
          ) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  static Future<Map<String, String>> _readPutMap(JsEngine engine) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify(__putMap)').timeout(evalTimeout))
            .value,
      );
      return {
        if (decoded is Map)
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value?.toString() ?? '',
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _mergePutMap(
    JsEngine engine,
    Map<String, String>? variables,
  ) async {
    if (variables == null) return;
    try {
      variables.addAll(await _readPutMap(engine));
    } catch (_) {
      // 变量读取失败不应影响规则结果
    }
  }

  static Future<void> _mergeCookies(
    JsEngine engine,
    Map<String, String>? cookies,
  ) async {
    if (cookies == null) return;
    try {
      final decoded = jsonDecode(
        (await engine
                .eval('JSON.stringify(__cookieStore)')
                .timeout(evalTimeout))
            .value,
      );
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          cookies[entry.key.toString()] = entry.value?.toString() ?? '';
        }
        for (final key in cookies.keys.toList()) {
          if (!decoded.containsKey(key)) cookies.remove(key);
        }
      }
    } catch (_) {
      // cookie 读取失败不应影响规则结果
    }
  }


  /// 预提取 java.get('字面量'[, 'attr']) → 查询缓存。
  /// 特殊键 'url'（Legado 取当前页 URL）返回 baseUrl。
  static Map<String, String> _extractLiterals(
    String html,
    String baseUrl,
    String body,
  ) {
    final cache = <String, String>{};
    final re = RegExp(
      "java\\.(get|getElement)\\(\\s*('([^']*)'|\"([^\"]*)\")(?:,\\s*('([^']*)'|\"([^\"]*)\"))?\\s*\\)",
    );
    final doc = parser.parse(html);
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
      final elements = RuleEngine.queryIn(doc, sel);
      final value = elements.isEmpty
          ? ''
          : (RuleEngine.valueOf(elements.first, attr) ?? '');
      cache[key] = value;
    }
    return cache;
  }

  static Map<String, String> _extractGetStringCache(String html, String body) {
    final cache = <String, String>{};
    final re = RegExp("java\\.getString\\(\\s*('([^']*)'|\"([^\"]*)\")");
    for (final m in re.allMatches(body)) {
      final path = m.group(2) ?? m.group(3) ?? '';
      if (path.isEmpty || cache.containsKey(path)) continue;
      cache[path] = _queryGetString(html, path);
    }
    return cache;
  }

  static String _queryGetString(String html, String path) {
    if (path.startsWith(r'$') || path.startsWith('.')) {
      try {
        final decoded = jsonDecode(html);
        if (decoded is Map<String, dynamic>) {
          final normalized = path.startsWith(r'$') || path.startsWith('.')
              ? path
              : '.$path';
          final values = JsonPathEngine.instance.query(decoded, normalized);
          if (values.isNotEmpty) {
            final value = values.first;
            if (value == null) return '';
            return value is String ? value : jsonEncode(value);
          }
        }
      } catch (_) {
        // JSON 解析失败时按 HTML 规则回退
      }
    }
    try {
      return RuleEngine.extractText(html, path) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Map<String, List<String>> _extractGetStringListCache(
    String html,
    String body,
  ) {
    final cache = <String, List<String>>{};
    final re = RegExp("java\\.getStringList\\(\\s*('([^']*)'|\"([^\"]*)\")");
    for (final m in re.allMatches(body)) {
      final path = m.group(2) ?? m.group(3) ?? '';
      if (path.isEmpty || cache.containsKey(path)) continue;
      cache[path] = _queryGetStringList(html, path);
    }
    return cache;
  }

  static List<String> _queryGetStringList(String html, String path) {
    if (path.startsWith(r'$') || path.startsWith('.')) {
      try {
        final decoded = jsonDecode(html);
        if (decoded is Map<String, dynamic>) {
          final normalized = path.startsWith(r'$') || path.startsWith('.')
              ? path
              : '.$path';
          final values = JsonPathEngine.instance.query(decoded, normalized);
          return [
            for (final value in values)
              if (value != null) value is String ? value : jsonEncode(value),
          ];
        }
      } catch (_) {
        // JSON 解析失败时按 HTML 规则回退
      }
    }
    try {
      return RuleEngine.extractTextList(html, path);
    } catch (_) {
      return const [];
    }
  }

  /// 注入执行环境：result/baseUrl + java 桥（预查询缓存 + 记录版 ajax）
  static String _prelude(
    String html,
    String baseUrl,
    Map<String, String> cache, {
    Map<String, String> getStringCache = const {},
    Map<String, List<String>> getStringListCache = const {},
    Map<String, String>? cookies,
  }) {
    final cacheJson = jsonEncode(cache);
    final getStringCacheJson = jsonEncode(getStringCache);
    final getStringListCacheJson = jsonEncode(getStringListCache);
    return '''
globalThis.result = ${_quote(html)};
globalThis.baseUrl = ${_quote(baseUrl)};
globalThis.__javaCache = $cacheJson;
globalThis.__getStringCache = $getStringCacheJson;
globalThis.__getStringListCache = $getStringListCacheJson;
globalThis.__putMap = {};
globalThis.__ajaxUrls = [];
globalThis.__ajaxCache = {};
globalThis.__postOps = [];
globalThis.__headOps = [];
globalThis.java = {
  put: (key, value) => { __putMap[String(key)] = String(value); return ''; },
  getString: (path) => __putMap[String(path)] || __getStringCache[String(path)] || __jsonPathGet(String(path), result) || '',
  getStringList: (path) => __getStringListCache[String(path)] || __jsonPathGetAll(String(path), result),
  get: (sel, attr) => __putMap[String(sel)] || __javaCache[sel + '|' + (attr || '')] || '',
  getElement: (sel, attr) => __putMap[String(sel)] || __javaCache[sel + '|' + (attr || '')] || '',
  ajax: (url) => { __ajaxUrls.push(String(url)); return ''; },
  post: (url, body, headers) => {
    __postOps.push([String(url), body === undefined || body === null ? '' : String(body), headers === undefined || headers === null ? {} : headers]);
    return { header: () => '', headers: () => ({}), cookies: () => '', body: () => '' };
  },
  head: (url, headers) => {
    __headOps.push([String(url), headers === undefined || headers === null ? {} : headers]);
    return { header: () => '', headers: () => ({}), cookies: () => '' };
  },
  log: () => '',
  toast: () => '',
  longToast: () => ''
};
$_cryptoRecordBridge
${_cookieBridge(cookies ?? const {}, seed: true)}''';
  }

  /// 记录模式环境：get/setContent 记录调用序列（docIndex 关联切换后的
  /// 文档），ajax 收集 URL 返回占位。规则执行后由 Dart 重放查询。
  static String _recordPrelude(
    String html,
    String baseUrl, {
    Map<String, String> getStringCache = const {},
    Map<String, List<String>> getStringListCache = const {},
    Map<String, String>? cookies,
  }) {
    final getStringCacheJson = jsonEncode(getStringCache);
    final getStringListCacheJson = jsonEncode(getStringListCache);
    return '''
globalThis.result = ${_quote(html)};
globalThis.baseUrl = ${_quote(baseUrl)};
globalThis.__ops = [];
globalThis.__docIndex = 0;
globalThis.__ajaxUrls = [];
globalThis.__ajaxCache = {};
globalThis.__postOps = [];
globalThis.__headOps = [];
globalThis.__putMap = {};
globalThis.__getStringCache = $getStringCacheJson;
globalThis.__getStringListCache = $getStringListCacheJson;
globalThis.java = {
  put: (key, value) => { __putMap[String(key)] = String(value); return ''; },
  getString: (path) => __putMap[String(path)] || __getStringCache[String(path)] || __jsonPathGet(String(path), result) || '',
  getStringList: (path) => __getStringListCache[String(path)] || __jsonPathGetAll(String(path), result),
  get: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    __ops.push(['get', String(sel), attr === undefined ? null : String(attr), __docIndex]);
    return '';
  },
  getElement: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    __ops.push(['get', String(sel), attr === undefined ? null : String(attr), __docIndex]);
    return '';
  },
  getElements: (sel) => {
    __ops.push(['getElements', String(sel), null, __docIndex]);
    return {
      length: 0,
      toArray: () => [],
      html: () => '',
      text: () => '',
      ownText: () => '',
      attr: () => '',
      get: () => ({ text: () => '', html: () => '', ownText: () => '', attr: () => '' }),
      first: () => ({ text: () => '', html: () => '', ownText: () => '', attr: () => '' }),
      last: () => ({ text: () => '', html: () => '', ownText: () => '', attr: () => '' })
    };
  },
  setContent: (html) => {
    __ops.push(['setContent', String(html)]);
    __docIndex++;
    return '';
  },
  ajax: (url) => { __ajaxUrls.push(String(url)); return ''; },
  post: (url, body, headers) => {
    __postOps.push([String(url), body === undefined || body === null ? '' : String(body), headers === undefined || headers === null ? {} : headers]);
    return { header: () => '', headers: () => ({}), cookies: () => '', body: () => '' };
  },
  head: (url, headers) => {
    __headOps.push([String(url), headers === undefined || headers === null ? {} : headers]);
    return { header: () => '', headers: () => ({}), cookies: () => '' };
  },
  log: () => '',
  toast: () => '',
  longToast: () => ''
};
$_cryptoRecordBridge
${_cookieBridge(cookies ?? const {}, seed: true)}''';
  }

  /// 最终执行环境：get 按记录顺序消费提取值表，setContent 为 no-op
  /// （doc 切换已由 Dart 重放完成），ajax 走真实结果缓存
  static const _finalPrelude = '''
globalThis.__getIdx = 0;
globalThis.java = {
  put: (key, value) => { __putMap[String(key)] = String(value); return ''; },
  getString: (path) => __putMap[String(path)] || __getStringCache[String(path)] || __jsonPathGet(String(path), result) || '',
  getStringList: (path) => __getStringListCache[String(path)] || __jsonPathGetAll(String(path), result),
  get: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    const v = __getValues[__getIdx++];
    return v === undefined || v === null ? '' : v;
  },
  getElement: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    const v = __getValues[__getIdx++];
    return v === undefined || v === null ? '' : v;
  },
  getElements: (sel) => {
    const items = __elementCaches[__getElementsIdx++] || [];
    const arr = items.map((snapshot) => ({
      html: () => snapshot.html,
      text: () => snapshot.text,
      ownText: () => snapshot.ownText,
      attr: (name) => name ? snapshot.attrs[String(name)] || '' : ''
    }));
    arr.toArray = () => arr.slice();
    arr.html = () => arr[0] ? arr[0].html() : '';
    arr.text = () => arr[0] ? arr[0].text() : '';
    arr.ownText = () => arr[0] ? arr[0].ownText() : '';
    arr.attr = (name) => arr[0] ? arr[0].attr(name) : '';
    arr.get = (i) => arr[i] || null;
    arr.first = () => arr[0] || null;
    arr.last = () => arr[arr.length - 1] || null;
    return arr;
  },
  setContent: (html) => '',
  ajax: (url) => __ajaxCache[String(url)] || '',
  log: () => '',
  toast: () => '',
  longToast: () => ''
};
''';

  /// 真实 ajax 桥：从预取缓存返回
  static const _ajaxRealBridge = '''
globalThis.java.ajax = (url) => __ajaxCache[String(url)] || '';
''';

  static const _networkRealBridge = '''
globalThis.__postCache = globalThis.__postCache || {};
globalThis.__headCache = globalThis.__headCache || {};
globalThis.java.post = (url, body, headers) => {
  const key = String(url) + '|' + (body === undefined || body === null ? '' : String(body)) + '|' + JSON.stringify(headers === undefined || headers === null ? {} : headers);
  const item = __postCache[key] || {headers: {}, cookies: '', body: ''};
  return {
    header: (name) => item.headers[String(name).toLowerCase()] || item.headers[String(name)] || '',
    headers: () => item.headers,
    cookies: () => item.cookies || '',
    body: () => item.body || ''
  };
};
globalThis.java.head = (url, headers) => {
  const key = String(url) + '||' + JSON.stringify(headers === undefined || headers === null ? {} : headers);
  const item = __headCache[key] || {headers: {}, cookies: ''};
  return {
    header: (name) => item.headers[String(name).toLowerCase()] || item.headers[String(name)] || '',
    headers: () => item.headers,
    cookies: () => item.cookies || ''
  };
};
''';

  static const _cryptoRecordBridge = '''
globalThis.__md5 = [];
globalThis.__md5Short = [];
globalThis.__base64 = [];
globalThis.__base64Decode = [];
globalThis.__base64DecodeByte = [];
globalThis.__hmac = [];
globalThis.__hmacBase64 = [];
globalThis.__digestHex = [];
globalThis.__aesDecode = [];
globalThis.__aesBase64Decode = [];
globalThis.__hexEncode = [];
globalThis.__hexDecode = [];
globalThis.__uri = [];
globalThis.__t2s = [];
globalThis.__uuidCount = 0;
globalThis.__time = [];
globalThis.__symmetric = [];
globalThis.__symmetricSeq = 0;
globalThis.__symmetricDecryptStr = [];
globalThis.__symmetricDecrypt = [];
globalThis.__symmetricEncrypt = [];
globalThis.__symmetricEncryptBase64 = [];
globalThis.__symmetricEncryptHex = [];
globalThis.java.md5Encode = (str) => { __md5.push(String(str)); return ''; };
globalThis.java.md5Encode16 = (str) => { __md5Short.push(String(str)); return ''; };
globalThis.java.base64Encode = (str) => { __base64.push(String(str)); return ''; };
globalThis.java.base64Decode = (str) => { __base64Decode.push(String(str)); return ''; };
globalThis.java.base64DecodeToByteArray = (str) => { __base64DecodeByte.push(String(str)); return []; };
globalThis.java.HMacHex = (data, algorithm, key) => { __hmac.push([String(data), String(algorithm), String(key)]); return ''; };
globalThis.java.HMacBase64 = (data, algorithm, key) => { __hmacBase64.push([String(data), String(algorithm), String(key)]); return ''; };
globalThis.java.digestHex = (data, algorithm) => { __digestHex.push([String(data), String(algorithm)]); return ''; };
globalThis.java.aesDecodeToString = (data, key, transformation, iv) => { __aesDecode.push([String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return ''; };
globalThis.java.aesBase64DecodeToString = (data, key, transformation, iv) => { __aesBase64Decode.push([String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return ''; };
globalThis.java.hexEncodeToString = (str) => { __hexEncode.push(String(str)); return ''; };
globalThis.java.hexDecodeToString = (hex) => { __hexDecode.push(String(hex)); return ''; };
globalThis.java.encodeURI = (str) => { __uri.push(String(str)); return ''; };
globalThis.java.t2s = (str) => { __t2s.push(String(str)); return ''; };
globalThis.java.s2t = (str) => { __s2t.push(String(str)); return ''; };
globalThis.java.randomUUID = () => { __uuidCount++; return ''; };
globalThis.java.timeFormat = (time, format) => { __time.push([String(time), format || '', 0]); return ''; };
globalThis.java.timeFormatUTC = (time, format, shift) => { __time.push([String(time), format || '', shift || 0]); return ''; };
globalThis.java.createSymmetricCrypto = (transformation, key, iv) => {
  const id = ++__symmetricSeq;
  __symmetric.push([id, String(transformation), key === undefined || key === null ? '' : String(key), iv === undefined || iv === null ? '' : String(iv)]);
  return {
    decryptStr: (data) => { __symmetricDecryptStr.push([id, String(data)]); return ''; },
    decrypt: (data) => { __symmetricDecrypt.push([id, String(data)]); return []; },
    encrypt: (data) => { __symmetricEncrypt.push([id, String(data)]); return []; },
    encryptBase64: (data) => { __symmetricEncryptBase64.push([id, String(data)]); return ''; },
    encryptHex: (data) => { __symmetricEncryptHex.push([id, String(data)]); return ''; }
  };
};
globalThis.java.desDecodeToString = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
globalThis.java.desBase64DecodeToString = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
globalThis.java.desEncodeToBase64String = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
globalThis.java.aesEncodeToBase64String = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
''';

  static String _cookieBridge(
    Map<String, String> cookies, {
    required bool seed,
  }) {
    final store = seed
        ? 'globalThis.__cookieStore = ${jsonEncode(cookies)};'
        : 'globalThis.__cookieStore = globalThis.__cookieStore || ${jsonEncode(cookies)};';
    return '''
$store
globalThis.__jsonPathGetAll = (path, source) => {
  try {
    const data = JSON.parse(String(source));
    let normalized = String(path).trim().replace(/^\\\$/, '');
    normalized = normalized.replace(/\\[['"]([^'"]+)['"]\\]/g, '.\$1');
    normalized = normalized.replace(/\\[(\\d+)\\]/g, '.[\$1]');
    normalized = normalized.replace(/\\.\\./g, '@@');
    const tokens = normalized.split('.').filter((p) => p !== '').map((p) => {
      if (p === '@@') return '..';
      if (p === '*') return '*';
      if (/^\\[\\d+\\]\$/.test(p)) return p.slice(1, -1);
      return p;
    });
    const resolve = (list, value) => {
      if (list.length === 0) return [value];
      const token = list[0];
      const rest = list.slice(1);
      if (token === '*') {
        const items = Array.isArray(value) ? value : (value && typeof value === 'object' ? Object.values(value) : []);
        const out = [];
        for (const item of items) out.push(...resolve(rest, item));
        return out;
      }
      if (token === '..') {
        const out = resolve(rest, value);
        if (value && typeof value === 'object') {
          for (const item of (Array.isArray(value) ? value : Object.values(value))) {
            out.push(...resolve(list, item));
          }
        }
        return out;
      }
      if (/^\\d+\$/.test(token)) {
        if (Array.isArray(value) && +token < value.length) return resolve(rest, value[+token]);
        return [];
      }
      if (Array.isArray(value)) {
        const out = [];
        for (const item of value) out.push(...resolve(list, item));
        return out;
      }
      if (value && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, token)) {
        return resolve(rest, value[token]);
      }
      return [];
    };
    return resolve(tokens, data).map((v) => typeof v === 'string' ? v : JSON.stringify(v));
  } catch (_) {
    return [];
  }
};
globalThis.__jsonPathGet = (path, source) => {
  const values = __jsonPathGetAll(path, source);
  return values.length > 0 ? values[0] : '';
};
globalThis.source = { getKey: () => baseUrl };
globalThis.cookie = {
  getCookie: (key) => __cookieStore[String(key)] || '',
  setCookie: (key, value) => { __cookieStore[String(key)] = String(value); return ''; },
  removeCookie: (key) => { delete __cookieStore[String(key)]; return ''; },
  replaceCookie: (key, name) => {
    const raw = String(__cookieStore[String(key)] || '');
    const next = raw.split(';').map((part) => part.trim()).filter((part) => part !== '' && part.split('=')[0] !== String(name)).join(';');
    __cookieStore[String(key)] = next;
    return next;
  }
};
globalThis.java.getCookie = (url, name) => {
  const raw = String(__cookieStore[String(url)] || '');
  if (name === undefined || name === null || name === '') return raw;
  const pair = raw.split(';').map((part) => part.trim()).find((part) => part.split('=')[0] === String(name));
  return pair ? pair.split('=').slice(1).join('=') : '';
};
globalThis.java.toNumChapter = (s) => {
  if (s === undefined || s === null) return s;
  const text = String(s);
  const m = text.match(/^(.*第)([零〇一二三四五六七八九十百千万0-9]+)(章.*)\$/);
  if (!m) return text;
  const cnDigits = m[2];
  if (!isNaN(Number(cnDigits))) return m[1] + Number(cnDigits) + m[3];
  const nums = {零:0,〇:0,一:1,二:2,三:3,四:4,五:5,六:6,七:7,八:8,九:9};
  let total = 0;
  let section = 0;
  let number = 0;
  for (const ch of cnDigits) {
    if (nums[ch] !== undefined) {
      number = nums[ch];
      continue;
    }
    if (ch === '十') {
      section += (number || 1) * 10;
      number = 0;
    } else if (ch === '百') {
      section += number * 100;
      number = 0;
    } else if (ch === '千') {
      section += number * 1000;
      number = 0;
    } else if (ch === '万') {
      section = (section + number) * 10000;
      total += section;
      section = 0;
      number = 0;
    } else if (ch === '亿') {
      total = (total + section + number) * 100000000;
      section = 0;
      number = 0;
    }
  }
  return m[1] + (total + section + number) + m[3];
};
globalThis.java.htmlFormat = (s) => {
  if (s === undefined || s === null) return '';
  return String(s)
    .replace(/<script[\\s\\S]*?<\\/script>/gi, '')
    .replace(/<style[\\s\\S]*?<\\/style>/gi, '')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .trim();
};
''';
  }

  static final _cryptoBridgeMarkers = [
    'java.md5',
    'java.base64',
    'java.aes',
    'java.hex',
    'java.encodeURI',
    'java.t2s',
    'java.s2t',
    'java.randomUUID',
    'java.HMac',
    'java.digestHex',
    'java.timeFormat',
    'java.createSymmetricCrypto',
    'java.des',
    'java.tripleDES',
  ];

  static bool _hasCryptoBridge(String body) =>
      _cryptoBridgeMarkers.any(body.contains);

  static String _quote(String s) {
    // JSON 字符串转义（含换行/引号），安全注入 JS 字符串字面量
    return jsonEncode(s);
  }
}


class _TemplateCaches {
  final Map<String, String> jsonCache;
  final Map<String, String> htmlCache;
  final Map<String, String> md5Cache;
  final Map<String, String> base64Cache;
  final Map<String, String> base64DecodeCache;
  final Map<String, String> base64DecodeByteCache;
  final Map<String, String> hmacCache;
  final Map<String, String> hmacBase64Cache;
  final Map<String, String> aesCache;
  final Map<String, String> aesBase64Cache;
  final Map<String, String> aesEncodeBase64Cache;
  final Map<String, String> hexEncodeCache;
  final Map<String, String> hexDecodeCache;
  final Map<String, String> uriCache;
  final Map<String, String> t2sCache;
  final Map<String, String> s2tCache;
  final List<String> uuidCache;
  final Map<String, String> putCache;
  final Map<String, String> timeCache;

  const _TemplateCaches({
    required this.jsonCache,
    required this.htmlCache,
    required this.md5Cache,
    required this.base64Cache,
    required this.base64DecodeCache,
    required this.base64DecodeByteCache,
    required this.hmacCache,
    required this.hmacBase64Cache,
    required this.aesCache,
    required this.aesBase64Cache,
    required this.aesEncodeBase64Cache,
    required this.hexEncodeCache,
    required this.hexDecodeCache,
    required this.uriCache,
    required this.t2sCache,
    required this.s2tCache,
    required this.uuidCache,
    required this.putCache,
    required this.timeCache,
  });

  int get argCount =>
      jsonCache.length +
      htmlCache.length +
      md5Cache.length +
      base64Cache.length +
      base64DecodeCache.length +
      base64DecodeByteCache.length +
      hmacCache.length +
      hmacBase64Cache.length +
      aesCache.length +
      aesBase64Cache.length +
      aesEncodeBase64Cache.length +
      hexEncodeCache.length +
      hexDecodeCache.length +
      uriCache.length +
      t2sCache.length +
      s2tCache.length +
      uuidCache.length +
      putCache.length +
      timeCache.length;
}


class _JsCryptoCaches {
  final Map<String, String> md5Cache;
  final Map<String, String> md5ShortCache;
  final Map<String, String> base64Cache;
  final Map<String, String> base64DecodeCache;
  final Map<String, String> base64DecodeByteCache;
  final Map<String, String> hmacCache;
  final Map<String, String> hmacBase64Cache;
  final Map<String, String> digestHexCache;
  final Map<String, String> aesCache;
  final Map<String, String> aesBase64Cache;
  final Map<String, String> hexEncodeCache;
  final Map<String, String> hexDecodeCache;
  final Map<String, String> uriCache;
  final Map<String, String> t2sCache;
  final Map<String, String> s2tCache;
  final List<String> uuidCache;
  final Map<String, String> timeCache;
  final Map<String, String> symmetricDecryptStrCache;
  final Map<String, String> symmetricDecryptCache;
  final Map<String, String> symmetricEncryptCache;
  final Map<String, String> symmetricEncryptBase64Cache;
  final Map<String, String> symmetricEncryptHexCache;

  const _JsCryptoCaches({
    required this.md5Cache,
    required this.md5ShortCache,
    required this.base64Cache,
    required this.base64DecodeCache,
    required this.base64DecodeByteCache,
    required this.hmacCache,
    required this.hmacBase64Cache,
    required this.digestHexCache,
    required this.aesCache,
    required this.aesBase64Cache,
    required this.hexEncodeCache,
    required this.hexDecodeCache,
    required this.uriCache,
    required this.t2sCache,
    required this.s2tCache,
    required this.uuidCache,
    required this.timeCache,
    required this.symmetricDecryptStrCache,
    required this.symmetricDecryptCache,
    required this.symmetricEncryptCache,
    required this.symmetricEncryptBase64Cache,
    required this.symmetricEncryptHexCache,
  });

  static Future<_JsCryptoCaches> fromEngine(JsEngine engine) async {
    final md5Args = await JsRuleExecutor._readStringList(engine, '__md5');
    final md5ShortArgs = await JsRuleExecutor._readStringList(
      engine,
      '__md5Short',
    );
    final base64Args = await JsRuleExecutor._readStringList(engine, '__base64');
    final base64DecodeArgs = await JsRuleExecutor._readStringList(
      engine,
      '__base64Decode',
    );
    final base64DecodeByteArgs = await JsRuleExecutor._readStringList(
      engine,
      '__base64DecodeByte',
    );
    final hmacArgs = await JsCrypto.readHmacArgs(engine, '__hmac');
    final hmacBase64Args = await JsCrypto.readHmacArgs(
      engine,
      '__hmacBase64',
    );
    final digestArgs = await JsCrypto.readDigestArgs(
      engine,
      '__digestHex',
    );
    final aesArgs = await JsCrypto.readAesArgs(engine, '__aesDecode');
    final aesBase64Args = await JsCrypto.readAesArgs(
      engine,
      '__aesBase64Decode',
    );
    final hexEncodeArgs = await JsRuleExecutor._readStringList(
      engine,
      '__hexEncode',
    );
    final hexDecodeArgs = await JsRuleExecutor._readStringList(
      engine,
      '__hexDecode',
    );
    final uriArgs = await JsRuleExecutor._readStringList(engine, '__uri');
    final t2sArgs = await JsRuleExecutor._readStringList(engine, '__t2s');
    final s2tArgs = await JsRuleExecutor._readStringList(engine, '__s2t');
    final uuidCount = await JsRuleExecutor._readInt(engine, '__uuidCount');
    final timeArgs = await JsCrypto.readTimeArgs(engine);
    final symmetricArgs = await JsCrypto.readSymmetricArgs(
      engine,
      '__symmetric',
    );
    final symmetricById = {for (final arg in symmetricArgs) arg.id: arg};
    final decryptStrOps = await JsCrypto.readSymmetricOps(
      engine,
      '__symmetricDecryptStr',
    );
    final decryptOps = await JsCrypto.readSymmetricOps(
      engine,
      '__symmetricDecrypt',
    );
    final encryptOps = await JsCrypto.readSymmetricOps(
      engine,
      '__symmetricEncrypt',
    );
    final encryptBase64Ops = await JsCrypto.readSymmetricOps(
      engine,
      '__symmetricEncryptBase64',
    );
    final encryptHexOps = await JsCrypto.readSymmetricOps(
      engine,
      '__symmetricEncryptHex',
    );

    Map<String, String> symmetricResults(
      List<SymmetricOp> ops,
      String Function(SymmetricArg arg, String data) compute,
    ) {
      return {
        for (final op in ops)
          if (symmetricById.containsKey(op.id))
            '${op.id}|${op.data}': compute(symmetricById[op.id]!, op.data),
      };
    }

    return _JsCryptoCaches(
      md5Cache: {
        for (final arg in md5Args)
          arg: md5.convert(utf8.encode(arg)).toString(),
      },
      md5ShortCache: {
        for (final arg in md5ShortArgs)
          arg: md5.convert(utf8.encode(arg)).toString().substring(0, 16),
      },
      base64Cache: {
        for (final arg in base64Args) arg: base64Encode(utf8.encode(arg)),
      },
      base64DecodeCache: {
        for (final arg in base64DecodeArgs)
          arg: JsCrypto.base64DecodeToString(arg),
      },
      base64DecodeByteCache: {
        for (final arg in base64DecodeByteArgs)
          arg: jsonEncode(JsCrypto.base64DecodeToBytes(arg)),
      },
      hmacCache: {
        for (final arg in hmacArgs) arg.cacheKey: JsCrypto.hmacHex(arg),
      },
      hmacBase64Cache: {
        for (final arg in hmacBase64Args)
          arg.cacheKey: JsCrypto.hmacBase64(arg),
      },
      digestHexCache: {
        for (final arg in digestArgs)
          '${arg.data}|${arg.algorithm}': JsCrypto.digestHex(arg),
      },
      aesCache: {
        for (final arg in aesArgs)
          arg.cacheKey: JsCrypto.aesDecodeToString(
            arg,
            base64Input: false,
          ),
      },
      aesBase64Cache: {
        for (final arg in aesBase64Args)
          arg.cacheKey: JsCrypto.aesDecodeToString(
            arg,
            base64Input: true,
          ),
      },
      hexEncodeCache: {
        for (final arg in hexEncodeArgs) arg: JsCrypto.hexEncode(arg),
      },
      hexDecodeCache: {
        for (final arg in hexDecodeArgs) arg: JsCrypto.hexDecode(arg),
      },
      uriCache: {
        for (final arg in uriArgs)
          arg: Uri.encodeComponent(arg).replaceAll('%20', '+'),
      },
      t2sCache: {
        for (final arg in t2sArgs)
          arg: ChineseConversion.convert(arg, ChineseConversionMode.simplified),
      },
      s2tCache: {
        for (final arg in s2tArgs)
          arg: ChineseConversion.convert(
            arg,
            ChineseConversionMode.traditional,
          ),
      },
      uuidCache: List.generate(uuidCount, (_) => JsCrypto.uuid4()),
      timeCache: {
        for (final arg in timeArgs)
          arg.key: JsCrypto.formatTimestamp(arg),
      },
      symmetricDecryptStrCache: symmetricResults(
        decryptStrOps,
        (arg, data) => JsCrypto.symmetricDecryptToString(arg, data),
      ),
      symmetricDecryptCache: symmetricResults(
        decryptOps,
        (arg, data) =>
            jsonEncode(JsCrypto.symmetricDecryptToBytes(arg, data)),
      ),
      symmetricEncryptCache: symmetricResults(
        encryptOps,
        (arg, data) =>
            jsonEncode(JsCrypto.symmetricEncryptToBytes(arg, data)),
      ),
      symmetricEncryptBase64Cache: symmetricResults(
        encryptBase64Ops,
        (arg, data) =>
            base64Encode(JsCrypto.symmetricEncryptToBytes(arg, data)),
      ),
      symmetricEncryptHexCache: symmetricResults(
        encryptHexOps,
        (arg, data) => JsCrypto.bytesToHex(
          JsCrypto.symmetricEncryptToBytes(arg, data),
        ),
      ),
    );
  }

  String get realBridge =>
      '''
globalThis.__md5Cache = ${jsonEncode(md5Cache)};
globalThis.__md5ShortCache = ${jsonEncode(md5ShortCache)};
globalThis.__base64Cache = ${jsonEncode(base64Cache)};
globalThis.__base64DecodeCache = ${jsonEncode(base64DecodeCache)};
globalThis.__base64DecodeByteCache = ${jsonEncode(base64DecodeByteCache)};
globalThis.__hmacCache = ${jsonEncode(hmacCache)};
globalThis.__hmacBase64Cache = ${jsonEncode(hmacBase64Cache)};
globalThis.__digestHexCache = ${jsonEncode(digestHexCache)};
globalThis.__aesCache = ${jsonEncode(aesCache)};
globalThis.__aesBase64Cache = ${jsonEncode(aesBase64Cache)};
globalThis.__hexEncodeCache = ${jsonEncode(hexEncodeCache)};
globalThis.__hexDecodeCache = ${jsonEncode(hexDecodeCache)};
globalThis.__uriCache = ${jsonEncode(uriCache)};
globalThis.__t2sCache = ${jsonEncode(t2sCache)};
globalThis.__uuidCache = ${jsonEncode(uuidCache)};
globalThis.__uuidIdx = 0;
globalThis.__timeCache = ${jsonEncode(timeCache)};
globalThis.__symmetricDecryptStrCache = ${jsonEncode(symmetricDecryptStrCache)};
globalThis.__symmetricDecryptCache = ${jsonEncode(symmetricDecryptCache)};
globalThis.__symmetricEncryptCache = ${jsonEncode(symmetricEncryptCache)};
globalThis.__symmetricEncryptBase64Cache = ${jsonEncode(symmetricEncryptBase64Cache)};
globalThis.__symmetricEncryptHexCache = ${jsonEncode(symmetricEncryptHexCache)};
globalThis.__symmetricCreateIdx = 0;
globalThis.java.md5Encode = (str) => __md5Cache[String(str)] || '';
globalThis.java.md5Encode16 = (str) => __md5ShortCache[String(str)] || '';
globalThis.java.base64Encode = (str) => __base64Cache[String(str)] || '';
globalThis.java.base64Decode = (str) => __base64DecodeCache[String(str)] || '';
globalThis.java.base64DecodeToByteArray = (str) => __base64DecodeByteCache[String(str)] ? JSON.parse(__base64DecodeByteCache[String(str)]) : [];
globalThis.java.HMacHex = (data, algorithm, key) => __hmacCache[String(data) + '|' + String(algorithm) + '|' + String(key)] || '';
globalThis.java.HMacBase64 = (data, algorithm, key) => __hmacBase64Cache[String(data) + '|' + String(algorithm) + '|' + String(key)] || '';
globalThis.java.digestHex = (data, algorithm) => __digestHexCache[String(data) + '|' + String(algorithm)] || '';
globalThis.java.aesDecodeToString = (data, key, transformation, iv) => __aesCache[String(data) + '|' + String(key) + '|' + String(transformation) + '|' + (iv === undefined || iv === null ? '' : String(iv))] || '';
globalThis.java.aesBase64DecodeToString = (data, key, transformation, iv) => __aesBase64Cache[String(data) + '|' + String(key) + '|' + String(transformation) + '|' + (iv === undefined || iv === null ? '' : String(iv))] || '';
globalThis.java.hexEncodeToString = (str) => __hexEncodeCache[String(str)] || '';
globalThis.java.hexDecodeToString = (hex) => __hexDecodeCache[String(hex)] || '';
globalThis.java.encodeURI = (str) => __uriCache[String(str)] || '';
globalThis.java.t2s = (str) => __t2sCache[String(str)] || '';
globalThis.java.s2t = (str) => __s2tCache[String(str)] || '';
globalThis.java.randomUUID = () => __uuidCache[__uuidIdx++] || '';
globalThis.java.timeFormat = (time, format) => __timeCache[String(time) + '|' + (format || '') + '|0'] || '';
globalThis.java.timeFormatUTC = (time, format, shift) => __timeCache[String(time) + '|' + (format || '') + '|' + (shift || 0)] || '';
globalThis.java.createSymmetricCrypto = (transformation, key, iv) => {
  const id = ++__symmetricCreateIdx;
  return {
    decryptStr: (data) => __symmetricDecryptStrCache[id + '|' + String(data)] || '',
    decrypt: (data) => __symmetricDecryptCache[id + '|' + String(data)] ? JSON.parse(__symmetricDecryptCache[id + '|' + String(data)]) : [],
    encrypt: (data) => __symmetricEncryptCache[id + '|' + String(data)] ? JSON.parse(__symmetricEncryptCache[id + '|' + String(data)]) : [],
    encryptBase64: (data) => __symmetricEncryptBase64Cache[id + '|' + String(data)] || '',
    encryptHex: (data) => __symmetricEncryptHexCache[id + '|' + String(data)] || ''
  };
};
globalThis.java.desDecodeToString = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
globalThis.java.desBase64DecodeToString = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
globalThis.java.desEncodeToBase64String = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
globalThis.java.aesEncodeToBase64String = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
''';
}
