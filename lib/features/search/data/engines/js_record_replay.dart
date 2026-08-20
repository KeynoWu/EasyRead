import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:easy_quickjs/quickjs.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'rule_engine.dart';
import 'js_crypto.dart';
import 'js_rule_executor.dart';
import '../../../settings/domain/entities/chinese_conversion.dart';

/// JS 桥记录-重放核心：java.get/setContent 调用序列的 Dart 重放与
/// 模板（java.getString 等）缓存读取与真实/记录 prelude 生成。
class JsRecordReplay {
  static Future<List<List<dynamic>>> readOps(JsEngine engine) async {
    final json =
        (await engine.eval('JSON.stringify(__ops)').timeout(JsRuleExecutor.evalTimeout)).value;
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
  replayOps(String html, List<List<dynamic>> ops) {
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
          for (final element in elements) elementSnapshot(element),
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

  static Map<String, dynamic> elementSnapshot(dom.Element element) {
    return {
      'html': element.outerHtml,
      'text': RuleEngine.valueOf(element, 'text') ?? '',
      'ownText': RuleEngine.valueOf(element, 'ownText') ?? '',
      'attrs': Map<String, String>.from(element.attributes),
    };
  }

  /// 解析 JSON 数组 URL 列表
  static List<String> parseUrls(String json) {
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






  static String templateRecordPrelude(
    Map<String, dynamic> json,
    String html,
    String baseUrl,
    int? page,
  ) {
    return '''
globalThis.result = ${JsRuleExecutor.quote(html)};
globalThis.baseUrl = ${JsRuleExecutor.quote(baseUrl)};
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

  static String templateRealPrelude(
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
  static Future<TemplateCaches> readTemplateCaches(
    JsEngine engine,
    Map<String, dynamic>? json,
    String? html,
  ) async {
    final jsonPaths = await readStringList(engine, '__jsonPaths');
    final htmlPaths = await readStringList(engine, '__htmlPaths');
    final t2sArgs = await readStringList(engine, '__t2s');
    final s2tArgs = await readStringList(engine, '__s2t');
    final uuidCount = await readInt(engine, '__uuidCount');
    final md5Args = await readStringList(engine, '__md5');
    final base64Args = await readStringList(engine, '__base64');
    final base64DecodeArgs = await readStringList(engine, '__base64Decode');
    final base64DecodeByteArgs = await readStringList(
      engine,
      '__base64DecodeByte',
    );
    final hmacArgs = await JsCrypto.readHmacArgs(engine, '__hmac');
    final hmacBase64Args = await JsCrypto.readHmacArgs(engine, '__hmacBase64');
    final aesArgs = await JsCrypto.readAesArgs(engine, '__aesDecode');
    final aesBase64Args = await JsCrypto.readAesArgs(engine, '__aesBase64Decode');
    final aesEncodeBase64Args = await JsCrypto.readAesArgs(engine, '__aesEncodeBase64');
    final hexEncodeArgs = await readStringList(engine, '__hexEncode');
    final hexDecodeArgs = await readStringList(engine, '__hexDecode');
    final uriArgs = await readStringList(engine, '__uri');
    final timeArgs = await JsCrypto.readTimeArgs(engine);
    final caches = TemplateCaches(
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
      putCache: await readPutMap(engine),
      timeCache: {for (final arg in timeArgs) arg.key: JsCrypto.formatTimestamp(arg)},
    );
    return caches;
  }
  static Future<List<String>> readStringList(
    JsEngine engine,
    String name,
  ) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify($name)').timeout(JsRuleExecutor.evalTimeout)).value,
      );
      return (decoded as List).map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<int> readInt(JsEngine engine, String name) async {
    try {
      return int.tryParse(
            (await engine.eval('JSON.stringify($name)').timeout(JsRuleExecutor.evalTimeout))
                .value,
          ) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  static Future<Map<String, String>> readPutMap(JsEngine engine) async {
    try {
      final decoded = jsonDecode(
        (await engine.eval('JSON.stringify(__putMap)').timeout(JsRuleExecutor.evalTimeout))
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
  static Future<void> mergePutMap(
    JsEngine engine,
    Map<String, String>? variables,
  ) async {
    if (variables == null) return;
    try {
      variables.addAll(await readPutMap(engine));
    } catch (_) {
      // 变量读取失败不应影响规则结果
    }
  }

  static Future<void> mergeCookies(
    JsEngine engine,
    Map<String, String>? cookies,
  ) async {
    if (cookies == null) return;
    try {
      final decoded = jsonDecode(
        (await engine
                .eval('JSON.stringify(__cookieStore)')
                .timeout(JsRuleExecutor.evalTimeout))
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


}

/// 模板执行缓存（从引擎读取的预计算值表）。
class TemplateCaches {
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

  const TemplateCaches({
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