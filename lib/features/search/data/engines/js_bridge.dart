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
    if (unsupportedMarkers.any(body.contains)) return true;
    // 剥离空白/引号/加号/点号等符号后再检查，防 'ev'+'al('、
    // '_ffi'+'Notify' 之类字符串拼接绕过（仍是纵深防御一层，
    // QuickJS 侧无 registerBridge、默认不绑定定时器，逃逸面已收窄）。
    final normalized = body.replaceAll(RegExp(r'[^A-Za-z0-9_()]'), '');
    return normalized.contains('_ffiNotify') ||
        normalized.contains('eval(') ||
        normalized.contains('startBrowser') ||
        normalized.contains('setTimeout');
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

  static Map<String, String> extractGetStringCache(String html, String body) {
    final cache = <String, String>{};
    final re = RegExp("java\\.getString\\(\\s*('([^']*)'|\"([^\"]*)\")");
    for (final m in re.allMatches(body)) {
      final path = m.group(2) ?? m.group(3) ?? '';
      if (path.isEmpty || cache.containsKey(path)) continue;
      cache[path] = queryGetString(html, path);
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
    final re = RegExp("java\\.getStringList\\(\\s*('([^']*)'|\"([^\"]*)\")");
    for (final m in re.allMatches(body)) {
      final path = m.group(2) ?? m.group(3) ?? '';
      if (path.isEmpty || cache.containsKey(path)) continue;
      cache[path] = queryGetStringList(html, path);
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
  }) {
    final cacheJson = jsonEncode(cache);
    final getStringCacheJson = jsonEncode(getStringCache);
    final getStringListCacheJson = jsonEncode(getStringListCache);
    return '''
globalThis.result = ${quote(html)};
globalThis.baseUrl = ${quote(baseUrl)};
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
$cryptoRecordBridge
${cookieBridge(cookies ?? const {}, seed: true)}''';
  }

  /// 记录模式环境：get/setContent 记录调用序列（docIndex 关联切换后的
  /// 文档），ajax 收集 URL 返回占位。规则执行后由 Dart 重放查询。
  static String recordPrelude(
    String html,
    String baseUrl, {
    Map<String, String> getStringCache = const {},
    Map<String, List<String>> getStringListCache = const {},
    Map<String, String>? cookies,
  }) {
    final getStringCacheJson = jsonEncode(getStringCache);
    final getStringListCacheJson = jsonEncode(getStringListCache);
    return '''
globalThis.result = ${quote(html)};
globalThis.baseUrl = ${quote(baseUrl)};
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
$cryptoRecordBridge
${cookieBridge(cookies ?? const {}, seed: true)}''';
  }

  /// 最终执行环境：get 按记录顺序消费提取值表，setContent 为 no-op
  static const finalPrelude = '''
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
