import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:easy_quickjs/quickjs.dart';
import '../../../../core/network/dio_client.dart';
import 'js_network.dart';
import 'js_record_replay.dart';
import 'js_bridge.dart';

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

  /// 可注入的请求实现；null 时走 DioClient。
  /// js_network 的并发抓取复用此注入点（生产依赖，非测试专用）。
  static Future<String> Function(String url)? fetcher;

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
  /// 创建引擎（带超时与失败回收）：引擎 isolate 死亡/挂死时
  /// createEngine 会永久等待，超时或以错误完成后回收允许下次重建
  static Future<JsEngine?> _createEngine(
    JsEngineManager manager,
    String prefix,
  ) async {
    try {
      return await manager
          .createEngine('$prefix${_engineSeq++}')
          .timeout(evalTimeout);
    } catch (_) {
      await _recycle();
      return null;
    }
  }
  /// 逐元素比对两组调用序列（readStringList 可能跨 isolate 类型化差异）
  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// jsLib 前缀：与规则体拼进同一次 eval，使 lib 顶层声明对规则体可见。
  static String _libPrefix(String? jsLib) {
    final lib = JsBridge.jsLibScript(jsLib);
    return lib.isEmpty ? '' : '$lib\n';
  }

  /// 执行 JS 规则，返回提取值；不支持/超时/异常返回 null
  static Future<String?> execute(
    String html,
    String rawRule, {
    String? baseUrl,
    String? charset,
    Map<String, String>? variables,
    Map<String, String>? cookies,
    String? jsLib,
  }) async {
    final body = JsBridge.scriptBody(rawRule);
    if (body == null || body.trim().isEmpty) return null;
    if (JsBridge.unsupported(body)) return null;
    final hasAjax = body.contains('java.ajax');
    final hasPost = body.contains('java.post');
    final hasHead = body.contains('java.head');
    final hasSetContent = body.contains('setContent');
    final hasGetElements = body.contains('java.getElements');
    final hasCrypto = JsBridge.hasCryptoBridge(body);

    final manager = await _getManager();
    if (manager == null) return null;
    final engine = await _createEngine(manager, 'jsrule');
    if (engine == null) return null;
    var recycled = false;
    try {
      if (!hasSetContent && !hasGetElements) {
        // 无 setContent：静态预提取 java.get 字面量 + 两遍 ajax
        List<String> warmSeq = const []; // 热身遍 crypto 调用序列（hasCrypto 时填充）
        final cache = JsBridge.extractLiterals(html, baseUrl ?? '', body);
        final getStringCache = JsBridge.extractGetStringCache(html, body);
        final getStringListCache = JsBridge.extractGetStringListCache(html, body);
        await engine
            .eval(
              JsBridge.prelude(
                html,
                baseUrl ?? '',
                cache,
                getStringCache: getStringCache,
                getStringListCache: getStringListCache,
                cookies: cookies,
                jsLib: jsLib,
              ),
            )
            .timeout(evalTimeout);

        if (hasAjax || hasCrypto || hasPost || hasHead) {
          await engine.eval('try { ${_libPrefix(jsLib)} $body } catch (e) {}').timeout(evalTimeout);
          // 用 try-catch 包裹——ajax 调用在异常前已记录 URL）
          if (hasAjax) {
            final urls = JsRecordReplay.parseUrls(
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
            await engine.eval(JsBridge.ajaxRealBridge).timeout(evalTimeout);
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
            await engine.eval(JsBridge.networkRealBridge).timeout(evalTimeout);
          }
        }

        if (hasCrypto) {
          // crypto 参数常依赖 ajax 真实结果（第一遍占位 '' 记录的参数有误）：
          // 真实网络桥装好后热身重录（cryptoRecordBridge 重置记录数组），
          // 再按真实参数重建缓存
          await engine.eval(JsBridge.cryptoRecordBridge).timeout(evalTimeout);
          await engine.eval('globalThis.__putMap = {};').timeout(evalTimeout);
          await engine.eval('try { ${_libPrefix(jsLib)} $body } catch (e) {}').timeout(evalTimeout);
          final crypto = await JsCryptoCaches.fromEngine(engine);
          // 记录热身遍 crypto 调用序列（realBridge 装入时 __cryptoSeq 会重置）
          warmSeq =
              await JsRecordReplay.readStringList(engine, '__cryptoSeq');
          await engine.eval(crypto.realBridge).timeout(evalTimeout);
        }

        // 第二遍前重置 putMap：之前各遍占位桥（ajax/crypto 返回 ''）
        // 推导的键值若残留，get/getString 会优先命中旧值而不重算
        await engine.eval('globalThis.__putMap = {};').timeout(evalTimeout);
        // 第二遍：执行取最终值（jsLib 前缀与规则体同串）
        final result =
            await engine.eval('${_libPrefix(jsLib)}$body').timeout(evalTimeout);
        // 最终遍 crypto 调用序列与热身遍不一致（控制流依赖 crypto 结果时
        // 调用次数/顺序变化 → symmetric id 错位）→ 降级，不静默给错值
        if (hasCrypto) {
          final finalSeq =
              await JsRecordReplay.readStringList(engine, '__cryptoSeq');
          if (!_sameList(warmSeq, finalSeq)) return null;
        }
        final value = result.value.trim();
        await JsRecordReplay.mergePutMap(engine, variables);
        await JsRecordReplay.mergeCookies(engine, cookies);
        return value.isEmpty || value == 'undefined' ? null : value;
      }

      // setContent 路径：记录-重放（见类注释）
      await engine
          .eval(
            JsBridge.recordPrelude(
              html,
              baseUrl ?? '',
              getStringCache: JsBridge.extractGetStringCache(html, body),
              getStringListCache: JsBridge.extractGetStringListCache(html, body),
              cookies: cookies,
            ),
          )
          .timeout(evalTimeout);
      await engine.eval('try { ${_libPrefix(jsLib)} $body } catch (e) {}').timeout(evalTimeout);
      var ops = await JsRecordReplay.readOps(engine);

      if (hasAjax || hasPost || hasHead) {
        if (hasAjax) {
          final urls = JsRecordReplay.parseUrls(
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
          await engine.eval(JsBridge.ajaxRealBridge).timeout(evalTimeout);
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
          await engine.eval(JsBridge.networkRealBridge).timeout(evalTimeout);
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
          await engine.eval('try { ${_libPrefix(jsLib)} $body } catch (e) {}').timeout(evalTimeout);
          ops = await JsRecordReplay.readOps(engine);
        }
      }

      // Dart 重放 doc 流 → 与记录顺序一致的提取值表/元素快照 → 注入
      final replay = JsRecordReplay.replayOps(html, ops);
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
      await engine.eval(JsBridge.finalPrelude).timeout(evalTimeout);
      await engine.eval(JsBridge.networkRealBridge).timeout(evalTimeout);
      await engine
          .eval(JsBridge.cookieBridge(cookies ?? const {}, seed: false))
          .timeout(evalTimeout);
      List<String> warmSeq = const []; // 热身遍 crypto 调用序列（hasCrypto 时填充）
      if (hasCrypto) {
        // crypto 参数常依赖提取值/ajax 真实结果（记录遍占位 '' 的参数有误）：
        // finalPrelude 装好后热身重录，按真实参数重建缓存
        await engine.eval(JsBridge.cryptoRecordBridge).timeout(evalTimeout);
        await engine.eval('globalThis.__putMap = {};').timeout(evalTimeout);
        await engine.eval('try { ${_libPrefix(jsLib)} $body } catch (e) {}').timeout(evalTimeout);
        final crypto = await JsCryptoCaches.fromEngine(engine);
        // 记录热身遍 crypto 调用序列（realBridge 装入时 __cryptoSeq 会重置）
        warmSeq =
            await JsRecordReplay.readStringList(engine, '__cryptoSeq');
        await engine.eval(crypto.realBridge).timeout(evalTimeout);
      }

      // 最终遍前复位：记录/热身遍消耗的提取值表索引、消费日志与
      // putMap 占位推导值都不能带入最终遍
      await engine
          .eval(
            'globalThis.__putMap = {};'
            'globalThis.__getIdx = 0;'
            'globalThis.__getElementsIdx = 0;'
            'globalThis.__getSelectors = [];',
          )
          .timeout(evalTimeout);

      // 最终遍：执行取最终值（jsLib 前缀与规则体同串）
      final result =
          await engine.eval('${_libPrefix(jsLib)}$body').timeout(evalTimeout);
      // 一致性校验：最终遍实际消费的 get/getElements 序列与记录遍不一致
      // （控制流依赖占位 '' 结果）时，值表已错位，结果不可信 → 降级
      if (await JsRecordReplay.isGetSequenceMismatch(engine, ops)) {
        return null;
      }
      // crypto 调用序列一致性：控制流依赖 crypto 结果导致两遍调用次数/
      // 顺序不同 → symmetric id 错位 → 降级，不静默给错值
      if (hasCrypto) {
        final finalSeq =
            await JsRecordReplay.readStringList(engine, '__cryptoSeq');
        if (!_sameList(warmSeq, finalSeq)) return null;
      }
      final value = result.value.trim();
      await JsRecordReplay.mergePutMap(engine, variables);
      await JsRecordReplay.mergeCookies(engine, cookies);
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
    final body = JsBridge.scriptBody(rawRule);
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
  /// 提取 js 标签包裹体或 at-js 前缀的脚本体

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
    // 逐表达式过黑名单：命中的表达式不参与求值（占位 ""），最终拼接时
    // 该项保留模板原文——合法数据字面量（如字段名含 setTimeout/_ffi）
    // 不再误伤整模板；`_ffiNotify` 类注入表达式也拿不到执行机会
    final expressions = [for (final match in matches) match.group(1)!.trim()];
    final blocked = <int>{};
    final bodyParts = <String>[];
    for (var i = 0; i < expressions.length; i++) {
      final expr = expressions[i];
      if (JsBridge.unsupported(expr)) {
        blocked.add(i);
        bodyParts.add('""');
      } else {
        bodyParts.add(expr);
      }
    }
    final body = 'JSON.stringify([${bodyParts.join(',')}])';

    final manager = await _getManager();
    if (manager == null) return template;
    final engine = await _createEngine(manager, 'jstemplate');
    if (engine == null) return template;
    var recycled = false;
    try {
      final recordPrelude = JsRecordReplay.templateRecordPrelude(
        json ?? const {},
        html ?? '',
        baseUrl ?? '',
        page,
      );
      await engine.eval(recordPrelude).timeout(evalTimeout);
      await engine
          .eval('try { $body } catch (e) { "[]" }')
          .timeout(evalTimeout);

      var caches = await JsRecordReplay.readTemplateCaches(engine, json, html);
      for (var round = 0; round < 4; round++) {
        await engine
            .eval(
              JsRecordReplay.templateRealPrelude(
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
        final next = await JsRecordReplay.readTemplateCaches(engine, json, html);
        if (next.argCount == caches.argCount) {
          caches = next;
          break;
        }
        caches = next;
      }
      await engine
          .eval(
            JsRecordReplay.templateRealPrelude(
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
        // 被黑名单拦下的表达式：保留模板原文（含 {{}}），其余正常插值
        buffer.write(blocked.contains(i)
            ? template.substring(match.start, match.end)
            : (decoded[i]?.toString() ?? ''));
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




  /// 特殊键 'url'（Legado 取当前页 URL）返回 baseUrl。
  /// 注入执行环境：result/baseUrl + java 桥（预查询缓存 + 记录版 ajax）
  /// （doc 切换已由 Dart 重放完成），ajax 走真实结果缓存
  /// 真实 ajax 桥：从预取缓存返回




}


