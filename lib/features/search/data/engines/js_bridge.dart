import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:easy_quickjs/quickjs.dart';
import 'package:html/parser.dart' as parser;
import 'json_path.dart';
import 'rule_engine.dart';
import '../../../settings/domain/entities/chinese_conversion.dart';
import 'js_crypto.dart';
import 'js_record_replay.dart';

/// JS 桥生成：java.* 记录/真实 prelude、cookie 桥、模板字面量预提取，
/// 以及 crypto 缓存桥（_JsCryptoCaches → JsCryptoCaches）。
class JsBridge {
  static String? scriptBody(String rule) {
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

  static const unsupportedMarkers = [
    'eval(',
    'startBrowser',
    'setTimeout',
    '_ffi',
  ];

  /// 黑名单命中：除直接匹配外，还剥离引号/空白后防字符串拼接绕过
  /// （如 'ev'+'al('、'_'+'ffi'+'Notify'）。仍是纵深防御一层——
  /// QuickJS 侧无 registerBridge、默认不绑定定时器，逃逸面已收窄。
  static bool unsupported(String body) {
    // 先解码 \uXXXX/\xXX 转义：'\u0065val('、'_ffi\u004eotify' 可绕过字面匹配
    final unescaped = _decodeJsEscapes(body);
    if (unsupportedMarkers.any(unescaped.contains)) return true;
    // 剥离空白/引号/加号/点号等符号后再检查，防 'ev'+'al('、
    // '_ffi'+'Notify' 之类字符串拼接绕过（仍是纵深防御一层，
    // QuickJS 侧无 registerBridge、默认不绑定定时器，逃逸面已收窄）。
    final normalized = unescaped.replaceAll(RegExp(r'[^A-Za-z0-9_()]'), '');
    return normalized.contains('_ffiNotify') ||
        normalized.contains('eval(') ||
        normalized.contains('startBrowser') ||
        normalized.contains('setTimeout');
  }
  /// 解码 JS 字符串转义（\uXXXX / \xXX），用于黑名单匹配前归一化。
  static String _decodeJsEscapes(String s) {
    if (!s.contains(r'\')) return s;
    return s
        .replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4})'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        )
        .replaceAllMapped(
          RegExp(r'\\x([0-9a-fA-F]{2})'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        );
  }
  static Map<String, String> extractLiterals(
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

  /// getString/getStringList 调用参数解析（逐字符，不依赖正则组）：
  /// 返回 (path, mContent, isUrl, unescape)。
  /// 引号参数为 mContent；布尔按位置：第 1 参布尔=unescape（Legado
  /// getString(rule, unescape) 重载）、第 2 参布尔=isUrl。
  static ({String path, String? mContent, bool isUrl, bool unescape})
  _parseGetStringCall(String call) {
    final open = call.indexOf('(');
    final close = call.lastIndexOf(')');
    if (open < 0 || close <= open) {
      return (path: '', mContent: null, isUrl: false, unescape: false);
    }
    var rest = call.substring(open + 1, close);
    final args = <String>[];
    while (rest.trim().isNotEmpty) {
      // 跳过前导逗号/空白（`('a', '', true)` 中的分隔符不作为参数）
      var r = rest.trimLeft();
      while (r.startsWith(',')) {
        r = r.substring(1).trimLeft();
      }
      if (r.isEmpty) break;
      if (r.startsWith("'") || r.startsWith('"')) {
        final quote = r[0];
        var end = 1;
        while (end < r.length && r[end] != quote) {
          end++;
        }
        args.add(r.substring(1, end));
        rest = end + 1 < r.length ? r.substring(end + 1) : '';
      } else {
        final comma = r.indexOf(',');
        if (comma < 0) {
          args.add(r);
          rest = '';
        } else {
          args.add(r.substring(0, comma).trim());
          rest = r.substring(comma + 1);
        }
      }
    }
    var path = args.isNotEmpty ? args[0] : '';
    String? mContent;
    var isUrl = false;
    var unescape = false;
    if (args.length > 1) {
      final second = args[1];
      if (second == 'true' || second == 'false') {
        unescape = second == 'true'; // Legado getString(rule, unescape)
      } else {
        mContent = second;
      }
    }
    if (args.length > 2) {
      final third = args[2];
      if (third == 'true' || third == 'false') {
        isUrl = third == 'true';
      } else if (mContent == null && third.isNotEmpty) {
        mContent = third;
      }
    }
    if (path.startsWith("'") || path.startsWith('"')) {
      path = path.substring(1, path.length - 1);
    }
    return (path: path, mContent: mContent, isUrl: isUrl, unescape: unescape);
  }

  /// HTML 实体反转义（Legado getString(rule, unescape) 语义）：
  /// 命名实体（amp/lt/gt/quot/apos）与数值实体（&#N; / &#xN;）
  static String htmlUnescape(String input) {
    if (!input.contains('&')) return input;
    final buffer = StringBuffer();
    final named = <String, String>{
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
    };
    var i = 0;
    while (i < input.length) {
      final amp = input.indexOf('&', i);
      if (amp < 0) {
        buffer.write(input.substring(i));
        break;
      }
      buffer.write(input.substring(i, amp));
      final semi = input.indexOf(';', amp);
      if (semi < 0 || semi - amp > 12) {
        buffer.write('&');
        i = amp + 1;
        continue;
      }
      final entity = input.substring(amp + 1, semi);
      String? decoded;
      if (entity.startsWith('#x') || entity.startsWith('#X')) {
        final code = int.tryParse(entity.substring(2), radix: 16);
        if (code != null) decoded = String.fromCharCode(code);
      } else if (entity.startsWith('#')) {
        final code = int.tryParse(entity.substring(1));
        if (code != null) decoded = String.fromCharCode(code);
      } else {
        decoded = named[entity];
      }
      if (decoded != null) {
        buffer.write(decoded);
        i = semi + 1;
      } else {
        buffer.write('&');
        i = amp + 1;
      }
    }
    return buffer.toString();
  }

  /// 相对 URL 解析为绝对（Legado getString(rule, mContent, isUrl) 语义）
  static String resolveIfUrl(String value, String baseUrl) {
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      try {
        final uri = Uri.parse(baseUrl).resolve(value);
        if (uri.scheme == 'http' || uri.scheme == 'https') {
          return uri.toString();
        }
      } catch (_) {}
    }
    return value;
  }

  static Map<String, String> extractGetStringCache(
    String html,
    String body, {
    String baseUrl = '',
  }) {
    final cache = <String, String>{};
    // java.getString('path'[, mContent][, isUrl]) / (rule, unescape)
    // 用调用级扫描 + 参数解析器（正则捕获组在 Dart RegExp 下嵌套可选组
    // 行为不稳，此处只找调用边界，参数逐字符解析）
    for (final call in RegExp(r'java\.getString\([^)]*\)').allMatches(body)) {
      final parsed = _parseGetStringCall(call.group(0)!);
      final path = parsed.path;
      if (path.isEmpty) continue;
      var mContent = parsed.mContent;
      var isUrlFlag = parsed.isUrl ? 'true' : '';
      var unescapeFlag = parsed.unescape ? 'true' : '';
      if (mContent != null && (mContent == 'true' || mContent == 'false')) {
        // 2 参单布尔重载：unescape（Legado AnalyzeRule.kt:251）
        unescapeFlag = mContent;
        mContent = null;
      }
      final key = '$path|${mContent ?? ''}|$isUrlFlag|$unescapeFlag';
      if (cache.containsKey(key)) continue;
      var value = queryGetString(html, path);
      if (mContent != null && mContent.isNotEmpty) {
        final fromContent = queryGetString(mContent, path);
        if (fromContent.isNotEmpty) value = fromContent;
      }
      if (isUrlFlag == 'true') value = resolveIfUrl(value, baseUrl);
      if (unescapeFlag == 'true') value = htmlUnescape(value);
      cache[key] = value;
    }
    return cache;
  }

  static String queryGetString(String html, String path) {
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

  static Map<String, List<String>> extractGetStringListCache(
    String html,
    String body,
  ) {
    final cache = <String, List<String>>{};
    for (final call
        in RegExp(r'java\.getStringList\([^)]*\)').allMatches(body)) {
      final parsed = _parseGetStringCall(call.group(0)!);
      final path = parsed.path;
      if (path.isEmpty) continue;
      var mContent = parsed.mContent;
      var isUrlFlag = parsed.isUrl ? 'true' : '';
      var unescapeFlag = parsed.unescape ? 'true' : '';
      if (mContent != null && (mContent == 'true' || mContent == 'false')) {
        unescapeFlag = mContent;
        mContent = null;
      }
      final key = '$path|${mContent ?? ''}|$isUrlFlag|$unescapeFlag';
      if (cache.containsKey(key)) continue;
      var values = queryGetStringList(html, path);
      if (mContent != null && mContent.isNotEmpty) {
        final fromContent = queryGetStringList(mContent, path);
        if (fromContent.isNotEmpty) values = fromContent;
      }
      if (unescapeFlag == 'true') {
        values = [for (final v in values) htmlUnescape(v)];
      }
      cache[key] = values;
    }
    return cache;
  }

  static List<String> queryGetStringList(String html, String path) {
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

  static String prelude(
    String html,
    String baseUrl,
    Map<String, String> cache, {
    Map<String, String> getStringCache = const {},
    Map<String, List<String>> getStringListCache = const {},
    Map<String, String>? cookies,
    String? jsLib,
    Map<String, String>? variables,
    Map<String, String>? cacheStore,
  }) {
    final cacheJson = jsonEncode(cache);
    final cacheStoreJson = jsonEncode(cacheStore ?? const {});
    final getStringCacheJson = jsonEncode(getStringCache);
    final getStringListCacheJson = jsonEncode(getStringListCache);
    final variablesJson = jsonEncode(variables ?? const {});
    // jsLib 不在此注入：与规则体同一次 eval 才能共享顶层声明，
    // 由 JsRuleExecutor._libPrefix 拼接（见 jsLibScript 文档）。
    return '''
globalThis.result = ${quote(html)};
globalThis.baseUrl = ${quote(baseUrl)};
globalThis.__javaCache = $cacheJson;
globalThis.__getStringCache = $getStringCacheJson;
globalThis.__getStringListCache = $getStringListCacheJson;
globalThis.__putMap = $variablesJson;
globalThis.__ajaxUrls = [];
globalThis.__ajaxCache = {};
globalThis.__postOps = [];
globalThis.__headOps = [];
globalThis.__ops = [];
globalThis.__docIndex = 0;
globalThis.__get2Ops = [];
globalThis.__get2Cache = globalThis.__get2Cache || {};
globalThis.__connectOps = [];
globalThis.__connectCache = globalThis.__connectCache || {};
globalThis.__g2h = (attr) => {
  try {
    return JSON.stringify(typeof attr === 'object' && attr !== null ? attr : JSON.parse(attr));
  } catch (e) { return '{}'; }
};
globalThis.__cacheStore = $cacheStoreJson;
globalThis.__cachePutOps = [];
globalThis.cache = {
  get: (key) => __cacheStore.hasOwnProperty(String(key)) ? __cacheStore[String(key)] : '',
  put: (key, value, saveTime) => {
    const v = String(value);
    const t = saveTime === undefined || saveTime === null ? 0 : saveTime;
    __cacheStore[String(key)] = v;
    __cachePutOps.push([String(key), v, t]);
    return '';
  }
};
globalThis.java = {
  put: (key, value) => { __putMap[String(key)] = String(value); return ''; },
  cache: cache,
  getString: (path, mContent, isUrl, unescape) => {
    let mc = '', isu = '', un = '';
    if (typeof mContent === 'boolean') { un = mContent ? 'true' : 'false'; }
    else { mc = mContent === undefined || mContent === null ? '' : String(mContent); }
    if (typeof isUrl === 'boolean') isu = isUrl ? 'true' : 'false';
    if (typeof unescape === 'boolean') un = unescape ? 'true' : 'false';
    const key = String(path) + '|' + mc + '|' + isu + '|' + un;
    return __putMap[String(path)] || __getStringCache[key] || __jsonPathGet(String(path), result) || '';
  },
  getStringList: (path, mContent, isUrl, unescape) => {
    let mc = '', isu = '', un = '';
    if (typeof mContent === 'boolean') { un = mContent ? 'true' : 'false'; }
    else { mc = mContent === undefined || mContent === null ? '' : String(mContent); }
    if (typeof isUrl === 'boolean') isu = isUrl ? 'true' : 'false';
    if (typeof unescape === 'boolean') un = unescape ? 'true' : 'false';
    const key = String(path) + '|' + mc + '|' + isu + '|' + un;
    return __getStringListCache[key] || __jsonPathGetAll(String(path), result);
  },
  get: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    if (attr !== undefined && attr !== null && (typeof attr === 'object' || (typeof attr === 'string' && attr.trim().startsWith('{')))) {
      const h = __g2h(attr);
      const key = String(sel) + '|' + h;
      if (__get2Cache[key] !== undefined) return __get2Cache[key];
      __get2Ops.push([String(sel), h]);
      return '';
    }
    // 静态预提取缓存 miss（运行时拼接的动态选择器）：记录 op 走
    // 记录-重放路径（P1-7），不再静默返回空
    const cached = __javaCache[sel + '|' + (attr || '')];
    if (cached !== undefined) return cached;
    __ops.push(['get', String(sel), attr === undefined ? null : String(attr), 0]);
    return '';
  },
  getElement: (sel, attr) => __putMap[String(sel)] || __javaCache[sel + '|' + (attr || '')] || '',
  ajax: (url) => {
    const cached = __ajaxCache[String(url)];
    if (cached !== undefined) return cached;
    __ajaxUrls.push(String(url));
    return '';
  },
  ajaxAll: (urls) => {
    const missing = [];
    (urls || []).forEach(function (u) {
      const k = String(u);
      if (__ajaxCache[k] === undefined) missing.push(k);
    });
    if (missing.length > 0) { __ajaxUrls.push.apply(__ajaxUrls, missing); return []; }
    return (urls || []).map(function (u) { return __ajaxCache[String(u)] || ''; });
  },
  connect: (url, headerJson) => {
    const h = headerJson === undefined || headerJson === null ? '{}' : (typeof headerJson === 'string' ? headerJson : JSON.stringify(headerJson));
    const key = String(url) + '|' + h;
    const cached = __connectCache[key];
    if (cached !== undefined) {
      return {
        status: () => cached.status || 0,
        header: (name) => cached.headers[String(name).toLowerCase()] || cached.headers[String(name)] || '',
        headers: () => cached.headers,
        cookies: () => cached.cookies,
        body: () => cached.body
      };
    }
    __connectOps.push([String(url), h]);
    return { status: () => 0, header: () => '', headers: () => ({}), cookies: () => '', body: () => '' };
  },
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
${cookieBridge(cookies ?? const {}, seed: true)}''';
  }

  /// 源级 jsLib：返回原始脚本语句（纯脚本原样；JSON 形式逐条换行拼接）。
  /// 由执行方与规则体拼进**同一次 eval**——顶层 const/let/function 在同一
  /// eval 内对规则体可见（对齐 Legado SharedJsScope 的作用域语义）。
  /// 注意：lib 语法错误会使该次 eval 整体失败（与 Legado 行为一致）。
  static String jsLibScript(String? jsLib) {
    if (jsLib == null || jsLib.trim().isEmpty) return '';
    final trimmed = jsLib.trim();
    if (!trimmed.startsWith('{')) {
      return trimmed;
    }
    try {
      final decoded = jsonDecode(trimmed) as Map<String, dynamic>;
      return decoded.values
          .map((v) => v?.toString() ?? '')
          .where((s) => s.trim().isNotEmpty)
          .join('\n');
    } catch (_) {
      return '';
    }
  }
  /// 记录模式环境：get/setContent 记录调用序列（docIndex 关联切换后的
  /// 文档），ajax 收集 URL 返回占位。规则执行后由 Dart 重放查询。
  static String recordPrelude(
    String html,
    String baseUrl, {
    Map<String, String> getStringCache = const {},
    Map<String, List<String>> getStringListCache = const {},
    Map<String, String>? cookies,
    Map<String, String>? variables,
    Map<String, String>? cacheStore,
  }) {
    final getStringCacheJson = jsonEncode(getStringCache);
    final getStringListCacheJson = jsonEncode(getStringListCache);
    final variablesJson = jsonEncode(variables ?? const {});
    final cacheStoreJson = jsonEncode(cacheStore ?? const {});
    return '''
globalThis.result = ${quote(html)};
globalThis.baseUrl = ${quote(baseUrl)};
globalThis.__ops = [];
globalThis.__docIndex = 0;
globalThis.__ajaxUrls = [];
globalThis.__ajaxCache = {};
globalThis.__postOps = [];
globalThis.__headOps = [];
globalThis.__get2Ops = [];
globalThis.__get2Cache = globalThis.__get2Cache || {};
globalThis.__connectOps = [];
globalThis.__connectCache = globalThis.__connectCache || {};
globalThis.__g2h = (attr) => {
  try {
    return JSON.stringify(typeof attr === 'object' && attr !== null ? attr : JSON.parse(attr));
  } catch (e) { return '{}'; }
};
globalThis.__putMap = $variablesJson;
globalThis.__cacheStore = $cacheStoreJson;
globalThis.__cachePutOps = [];
globalThis.cache = {
  get: (key) => __cacheStore.hasOwnProperty(String(key)) ? __cacheStore[String(key)] : '',
  put: (key, value, saveTime) => {
    const v = String(value);
    const t = saveTime === undefined || saveTime === null ? 0 : saveTime;
    __cacheStore[String(key)] = v;
    __cachePutOps.push([String(key), v, t]);
    return '';
  }
};
globalThis.__getStringCache = $getStringCacheJson;
globalThis.__getStringListCache = $getStringListCacheJson;
globalThis.java = {
  put: (key, value) => { __putMap[String(key)] = String(value); return ''; },
  cache: cache,
  getString: (path, mContent, isUrl, unescape) => {
    let mc = '', isu = '', un = '';
    if (typeof mContent === 'boolean') { un = mContent ? 'true' : 'false'; }
    else { mc = mContent === undefined || mContent === null ? '' : String(mContent); }
    if (typeof isUrl === 'boolean') isu = isUrl ? 'true' : 'false';
    if (typeof unescape === 'boolean') un = unescape ? 'true' : 'false';
    const key = String(path) + '|' + mc + '|' + isu + '|' + un;
    return __putMap[String(path)] || __getStringCache[key] || __jsonPathGet(String(path), result) || '';
  },
  getStringList: (path, mContent, isUrl, unescape) => {
    let mc = '', isu = '', un = '';
    if (typeof mContent === 'boolean') { un = mContent ? 'true' : 'false'; }
    else { mc = mContent === undefined || mContent === null ? '' : String(mContent); }
    if (typeof isUrl === 'boolean') isu = isUrl ? 'true' : 'false';
    if (typeof unescape === 'boolean') un = unescape ? 'true' : 'false';
    const key = String(path) + '|' + mc + '|' + isu + '|' + un;
    return __getStringListCache[key] || __jsonPathGetAll(String(path), result);
  },
  get: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    if (attr !== undefined && attr !== null && (typeof attr === 'object' || (typeof attr === 'string' && attr.trim().startsWith('{')))) {
      __get2Ops.push([String(sel), __g2h(attr)]);
      return '';
    }
    __ops.push(['get', String(sel), attr === undefined ? null : String(attr), __docIndex]);
    return '';
  },
  getElement: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    if (attr === undefined || attr === null) {
      __ops.push(['getElement', String(sel), null, __docIndex]);
      return { html: () => '', text: () => '', ownText: () => '', attr: () => '' };
    }
    __ops.push(['get', String(sel), String(attr), __docIndex]);
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
  ajax: (url) => {
    const cached = __ajaxCache[String(url)];
    if (cached !== undefined) return cached;
    __ajaxUrls.push(String(url));
    return '';
  },
  ajaxAll: (urls) => {
    const missing = [];
    (urls || []).forEach(function (u) {
      const k = String(u);
      if (__ajaxCache[k] === undefined) missing.push(k);
    });
    if (missing.length > 0) { __ajaxUrls.push.apply(__ajaxUrls, missing); return []; }
    return (urls || []).map(function (u) { return __ajaxCache[String(u)] || ''; });
  },
  connect: (url, headerJson) => {
    const h = headerJson === undefined || headerJson === null ? '{}' : (typeof headerJson === 'string' ? headerJson : JSON.stringify(headerJson));
    const key = String(url) + '|' + h;
    const cached = __connectCache[key];
    if (cached !== undefined) {
      return {
        status: () => cached.status || 0,
        header: (name) => cached.headers[String(name).toLowerCase()] || cached.headers[String(name)] || '',
        headers: () => cached.headers,
        cookies: () => cached.cookies,
        body: () => cached.body
      };
    }
    __connectOps.push([String(url), h]);
    return { status: () => 0, header: () => '', headers: () => ({}), cookies: () => '', body: () => '' };
  },
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
$cryptoRecordBridge
${cookieBridge(cookies ?? const {}, seed: true)}''';
  }

  /// 最终执行环境：get 按记录顺序消费提取值表，setContent 为 no-op。
  /// 两参 get(url, headers) 走网络缓存（__get2Cache，键= url|headersJson，
  /// 与 Dart 侧 NetworkOp.key 归一规则一致）。
  static const finalPrelude = '''
globalThis.__getIdx = 0;
globalThis.__docIndex = 0;
globalThis.__getSelectors = [];
globalThis.__get2Cache = globalThis.__get2Cache || {};
globalThis.__g2h = (attr) => {
  try {
    return JSON.stringify(typeof attr === 'object' && attr !== null ? attr : JSON.parse(attr));
  } catch (e) { return '{}'; }
};
globalThis.__cacheStore = globalThis.__cacheStore || {};
globalThis.__cachePutOps = globalThis.__cachePutOps || [];
globalThis.cache = {
  get: (key) => __cacheStore.hasOwnProperty(String(key)) ? __cacheStore[String(key)] : '',
  put: (key, value, saveTime) => {
    const v = String(value);
    const t = saveTime === undefined || saveTime === null ? 0 : saveTime;
    __cacheStore[String(key)] = v;
    __cachePutOps.push([String(key), v, t]);
    return '';
  }
};
globalThis.java = {
  put: (key, value) => { __putMap[String(key)] = String(value); return ''; },
  cache: cache,
  getString: (path, mContent, isUrl, unescape) => {
    let mc = '', isu = '', un = '';
    if (typeof mContent === 'boolean') { un = mContent ? 'true' : 'false'; }
    else { mc = mContent === undefined || mContent === null ? '' : String(mContent); }
    if (typeof isUrl === 'boolean') isu = isUrl ? 'true' : 'false';
    if (typeof unescape === 'boolean') un = unescape ? 'true' : 'false';
    const key = String(path) + '|' + mc + '|' + isu + '|' + un;
    return __putMap[String(path)] || __getStringCache[key] || __jsonPathGet(String(path), result) || '';
  },
  getStringList: (path, mContent, isUrl, unescape) => {
    let mc = '', isu = '', un = '';
    if (typeof mContent === 'boolean') { un = mContent ? 'true' : 'false'; }
    else { mc = mContent === undefined || mContent === null ? '' : String(mContent); }
    if (typeof isUrl === 'boolean') isu = isUrl ? 'true' : 'false';
    if (typeof unescape === 'boolean') un = unescape ? 'true' : 'false';
    const key = String(path) + '|' + mc + '|' + isu + '|' + un;
    return __getStringListCache[key] || __jsonPathGetAll(String(path), result);
  },
  get: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    if (attr !== undefined && attr !== null && (typeof attr === 'object' || (typeof attr === 'string' && attr.trim().startsWith('{')))) {
      return __get2Cache[String(sel) + '|' + __g2h(attr)] || '';
    }
    __getSelectors.push('g|' + String(sel) + '|' + (attr === undefined || attr === null ? '' : String(attr)));
    const v = __getValues[__getIdx++];
    return v === undefined || v === null ? '' : v;
  },
  getElement: (sel, attr) => {
    if (__putMap.hasOwnProperty(String(sel))) return __putMap[String(sel)];
    if (String(sel) === 'url') return baseUrl;
    if (attr === undefined || attr === null) {
      const items = __elementCaches[__docIndex + '|' + String(sel)] || [];
      const e = items.length > 0 ? items[0] : null;
      return {
        html: () => e ? e.html : '',
        text: () => e ? e.text : '',
        ownText: () => e ? e.ownText : '',
        attr: (name) => e ? (name ? e.attrs[String(name)] || '' : '') : ''
      };
    }
    __getSelectors.push('g|' + String(sel) + '|' + String(attr));
    const v = __getValues[__getIdx++];
    return v === undefined || v === null ? '' : v;
  },
  getElements: (sel) => {
    const items = __elementCaches[__docIndex + '|' + String(sel)] || [];
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
  setContent: (html) => { __docIndex++; return ''; },
  ajax: (url) => __ajaxCache[String(url)] || '',
  ajaxAll: (urls) => (urls || []).map(function (u) { return __ajaxCache[String(u)] || ''; }),
  connect: (url, headerJson) => {
    const h = headerJson === undefined || headerJson === null ? '{}' : (typeof headerJson === 'string' ? headerJson : JSON.stringify(headerJson));
    const key = String(url) + '|' + h;
    const item = __connectCache[key] || {status: 0, headers: {}, cookies: '', body: ''};
    return {
      status: () => item.status,
      header: (name) => item.headers[String(name).toLowerCase()] || item.headers[String(name)] || '',
      headers: () => item.headers,
      cookies: () => item.cookies,
      body: () => item.body
    };
  },
  log: () => '',
  toast: () => '',
  longToast: () => ''
};
''';

  static const ajaxRealBridge = '''
globalThis.java.ajax = (url) => __ajaxCache[String(url)] || '';
''';
  static const networkRealBridge = '''
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
  static const cryptoRecordBridge = '''
globalThis.__cryptoSeq = [];
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
globalThis.java.md5Encode = (str) => { __cryptoSeq.push('md5Encode');  __md5.push(String(str)); return ''; };
globalThis.java.md5Encode16 = (str) => { __cryptoSeq.push('md5Encode16');  __md5Short.push(String(str)); return ''; };
globalThis.java.base64Encode = (str) => { __cryptoSeq.push('base64Encode');  __base64.push(String(str)); return ''; };
globalThis.java.base64Decode = (str) => { __cryptoSeq.push('base64Decode');  __base64Decode.push(String(str)); return ''; };
globalThis.java.base64DecodeToByteArray = (str) => { __cryptoSeq.push('base64DecodeToByteArray');  __base64DecodeByte.push(String(str)); return []; };
globalThis.java.HMacHex = (data, algorithm, key) => { __cryptoSeq.push('HMacHex');  __hmac.push([String(data), String(algorithm), String(key)]); return ''; };
globalThis.java.HMacBase64 = (data, algorithm, key) => { __cryptoSeq.push('HMacBase64');  __hmacBase64.push([String(data), String(algorithm), String(key)]); return ''; };
globalThis.java.digestHex = (data, algorithm) => { __cryptoSeq.push('digestHex');  __digestHex.push([String(data), String(algorithm)]); return ''; };
globalThis.java.aesDecodeToString = (data, key, transformation, iv) => { __cryptoSeq.push('aesDecodeToString');  __aesDecode.push([String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return ''; };
globalThis.java.aesBase64DecodeToString = (data, key, transformation, iv) => { __cryptoSeq.push('aesBase64DecodeToString');  __aesBase64Decode.push([String(data), String(key), String(transformation), iv === undefined || iv === null ? '' : String(iv)]); return ''; };
globalThis.java.hexEncodeToString = (str) => { __cryptoSeq.push('hexEncodeToString');  __hexEncode.push(String(str)); return ''; };
globalThis.java.hexDecodeToString = (hex) => { __cryptoSeq.push('hexDecodeToString');  __hexDecode.push(String(hex)); return ''; };
globalThis.java.encodeURI = (str) => { __cryptoSeq.push('encodeURI');  __uri.push(String(str)); return ''; };
globalThis.java.t2s = (str) => { __cryptoSeq.push('t2s');  __t2s.push(String(str)); return ''; };
globalThis.java.s2t = (str) => { __cryptoSeq.push('s2t');  __s2t.push(String(str)); return ''; };
globalThis.java.randomUUID = () => { __cryptoSeq.push('randomUUID');  __uuidCount++; return ''; };
globalThis.java.timeFormat = (time, format) => { __cryptoSeq.push('timeFormat');  __time.push([String(time), format || '', 0]); return ''; };
globalThis.java.timeFormatUTC = (time, format, shift) => { __cryptoSeq.push('timeFormatUTC');  __time.push([String(time), format || '', shift || 0]); return ''; };
globalThis.java.createSymmetricCrypto = (transformation, key, iv) => {
  __cryptoSeq.push('createSymmetricCrypto');
  const id = ++__symmetricSeq;
  __symmetric.push([id, String(transformation), key === undefined || key === null ? '' : String(key), iv === undefined || iv === null ? '' : String(iv)]);
  return {
    decryptStr: (data) => { __cryptoSeq.push('sym.decryptStr');  __symmetricDecryptStr.push([id, String(data)]); return ''; },
    decrypt: (data) => { __cryptoSeq.push('sym.decrypt');  __symmetricDecrypt.push([id, String(data)]); return []; },
    encrypt: (data) => { __cryptoSeq.push('sym.encrypt');  __symmetricEncrypt.push([id, String(data)]); return []; },
    encryptBase64: (data) => { __cryptoSeq.push('sym.encryptBase64');  __symmetricEncryptBase64.push([id, String(data)]); return ''; },
    encryptHex: (data) => { __cryptoSeq.push('sym.encryptHex');  __symmetricEncryptHex.push([id, String(data)]); return ''; }
  };
};
globalThis.java.desDecodeToString = (data, key, transformation, iv) => (__cryptoSeq.push('desDecodeToString'), java.createSymmetricCrypto(transformation, key, iv).decryptStr(data));
globalThis.java.desBase64DecodeToString = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
globalThis.java.desEncodeToBase64String = (data, key, transformation, iv) => (__cryptoSeq.push('desEncodeToBase64String'), java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data));
globalThis.java.aesEncodeToBase64String = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
''';
  static String cookieBridge(
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
// cookie 二级域名归一化（§三-7，Legado CookieStore.getSubDomain 语义）：
// 取 URL 的主机名；主机为 IP 或不足两段时原样返回，否则取末两段
// （www.ex.com / m.ex.com → ex.com）。
globalThis.__subdomainOf = (url) => {
  try {
    const m = String(url).match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\\/\\/([^\\/?#]+)/);
    if (!m) return String(url);
    const host = String(m[1]).split('@').pop().split(':')[0];
    if (/^\\d{1,3}(\\.\\d{1,3}){3}\$/.test(host) || host.indexOf('.') < 0) return host;
    const parts = host.split('.');
    if (parts.length <= 2) return host;
    return parts.slice(-2).join('.');
  } catch (e) { return String(url); }
};
// 键查找：精确键 → 同主机键 → 同二级域名键兜底（登录 cookie 存于 www
// 域时 m 域请求仍可读到；同源主机精确命中优先）
globalThis.__hostOf = (url) => {
  try {
    const m = String(url).match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\\/\\/([^\\/?#]+)/);
    if (!m) return String(url);
    return String(m[1]).split('@').pop().split(':')[0];
  } catch (e) { return String(url); }
};
globalThis.__cookieLookup = (key) => {
  const exact = __cookieStore[String(key)];
  if (exact !== undefined && exact !== '') return exact;
  const host = __hostOf(key);
  const domain = __subdomainOf(key);
  const keys = Object.keys(__cookieStore);
  for (const k of keys) {
    if (__hostOf(k) === host) return __cookieStore[k];
  }
  for (const k of keys) {
    if (__subdomainOf(k) === domain) return __cookieStore[k];
  }
  return '';
};
globalThis.cookie = {
  getCookie: (key) => __cookieLookup(key),
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
  const raw = String(__cookieLookup(url));
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
  static bool hasCryptoBridge(String body) =>
      _cryptoBridgeMarkers.any(body.contains);

  static String quote(String s) {
    // JSON 字符串转义（含换行/引号），安全注入 JS 字符串字面量
    return jsonEncode(s);
  }
}

class JsCryptoCaches {
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

  const JsCryptoCaches({
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

  static Future<JsCryptoCaches> fromEngine(JsEngine engine) async {
    final md5Args = await JsRecordReplay.readStringList(engine, '__md5');
    final md5ShortArgs = await JsRecordReplay.readStringList(
      engine,
      '__md5Short',
    );
    final base64Args = await JsRecordReplay.readStringList(engine, '__base64');
    final base64DecodeArgs = await JsRecordReplay.readStringList(
      engine,
      '__base64Decode',
    );
    final base64DecodeByteArgs = await JsRecordReplay.readStringList(
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
    final hexEncodeArgs = await JsRecordReplay.readStringList(
      engine,
      '__hexEncode',
    );
    final hexDecodeArgs = await JsRecordReplay.readStringList(
      engine,
      '__hexDecode',
    );
    final uriArgs = await JsRecordReplay.readStringList(engine, '__uri');
    final t2sArgs = await JsRecordReplay.readStringList(engine, '__t2s');
    final s2tArgs = await JsRecordReplay.readStringList(engine, '__s2t');
    final uuidCount = await JsRecordReplay.readInt(engine, '__uuidCount');
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

    return JsCryptoCaches(
      md5Cache: {
        for (final arg in md5Args)
          arg: md5.convert(utf8.encode(arg)).toString(),
      },
      md5ShortCache: {
        for (final arg in md5ShortArgs)
          // Legado md5Encode16 = md5 hex 中段 16 位（MD5Utils.kt:27-30
          // substring(8, 24)），非前 16 位
          arg: md5.convert(utf8.encode(arg)).toString().substring(8, 24),
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
globalThis.__cryptoSeq = [];
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
globalThis.java.md5Encode = (str) =>  { __cryptoSeq.push('md5Encode'); return __md5Cache[String(str)] || ''; };
globalThis.java.md5Encode16 = (str) =>  { __cryptoSeq.push('md5Encode16'); return __md5ShortCache[String(str)] || ''; };
globalThis.java.base64Encode = (str) =>  { __cryptoSeq.push('base64Encode'); return __base64Cache[String(str)] || ''; };
globalThis.java.base64Decode = (str) =>  { __cryptoSeq.push('base64Decode'); return __base64DecodeCache[String(str)] || ''; };
globalThis.java.base64DecodeToByteArray = (str) =>  { __cryptoSeq.push('base64DecodeToByteArray'); return __base64DecodeByteCache[String(str)] ? JSON.parse(__base64DecodeByteCache[String(str)]) : []; };
globalThis.java.HMacHex = (data, algorithm, key) =>  { __cryptoSeq.push('HMacHex'); return __hmacCache[String(data) + '|' + String(algorithm) + '|' + String(key)] || ''; };
globalThis.java.HMacBase64 = (data, algorithm, key) =>  { __cryptoSeq.push('HMacBase64'); return __hmacBase64Cache[String(data) + '|' + String(algorithm) + '|' + String(key)] || ''; };
globalThis.java.digestHex = (data, algorithm) =>  { __cryptoSeq.push('digestHex'); return __digestHexCache[String(data) + '|' + String(algorithm)] || ''; };
globalThis.java.aesDecodeToString = (data, key, transformation, iv) =>  { __cryptoSeq.push('aesDecodeToString'); return __aesCache[String(data) + '|' + String(key) + '|' + String(transformation) + '|' + (iv === undefined || iv === null ? '' : String(iv))] || ''; };
globalThis.java.aesBase64DecodeToString = (data, key, transformation, iv) =>  { __cryptoSeq.push('aesBase64DecodeToString'); return __aesBase64Cache[String(data) + '|' + String(key) + '|' + String(transformation) + '|' + (iv === undefined || iv === null ? '' : String(iv))] || ''; };
globalThis.java.hexEncodeToString = (str) =>  { __cryptoSeq.push('hexEncodeToString'); return __hexEncodeCache[String(str)] || ''; };
globalThis.java.hexDecodeToString = (hex) =>  { __cryptoSeq.push('hexDecodeToString'); return __hexDecodeCache[String(hex)] || ''; };
globalThis.java.encodeURI = (str) =>  { __cryptoSeq.push('encodeURI'); return __uriCache[String(str)] || ''; };
globalThis.java.t2s = (str) =>  { __cryptoSeq.push('t2s'); return __t2sCache[String(str)] || ''; };
globalThis.java.s2t = (str) =>  { __cryptoSeq.push('s2t'); return __s2tCache[String(str)] || ''; };
globalThis.java.randomUUID = () =>  { __cryptoSeq.push('randomUUID'); return __uuidCache[__uuidIdx++] || ''; };
globalThis.java.timeFormat = (time, format) =>  { __cryptoSeq.push('timeFormat'); return __timeCache[String(time) + '|' + (format || '') + '|0'] || ''; };
globalThis.java.timeFormatUTC = (time, format, shift) =>  { __cryptoSeq.push('timeFormatUTC'); return __timeCache[String(time) + '|' + (format || '') + '|' + (shift || 0)] || ''; };
globalThis.java.createSymmetricCrypto = (transformation, key, iv) => {
  __cryptoSeq.push('createSymmetricCrypto');
  const id = ++__symmetricCreateIdx;
  return {
    decryptStr: (data) => { __cryptoSeq.push('sym.decryptStr'); return __symmetricDecryptStrCache[id + '|' + String(data)] || ''; },
    decrypt: (data) => { __cryptoSeq.push('sym.decrypt'); return __symmetricDecryptCache[id + '|' + String(data)] ? JSON.parse(__symmetricDecryptCache[id + '|' + String(data)]) : []; },
    encrypt: (data) => { __cryptoSeq.push('sym.encrypt'); return __symmetricEncryptCache[id + '|' + String(data)] ? JSON.parse(__symmetricEncryptCache[id + '|' + String(data)]) : []; },
    encryptBase64: (data) => { __cryptoSeq.push('sym.encryptBase64'); return __symmetricEncryptBase64Cache[id + '|' + String(data)] || ''; },
    encryptHex: (data) => { __cryptoSeq.push('sym.encryptHex'); return __symmetricEncryptHexCache[id + '|' + String(data)] || ''; }
  };
};
globalThis.java.desDecodeToString = (data, key, transformation, iv) => (__cryptoSeq.push('desDecodeToString'), java.createSymmetricCrypto(transformation, key, iv).decryptStr(data));
globalThis.java.desBase64DecodeToString = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
globalThis.java.desEncodeToBase64String = (data, key, transformation, iv) => (__cryptoSeq.push('desEncodeToBase64String'), java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data));
globalThis.java.aesEncodeToBase64String = (data, key, transformation, iv) => java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
''';
}
