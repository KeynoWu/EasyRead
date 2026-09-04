import 'dart:convert';

/// Legado AnalyzeUrl 的 URL 规格解析（机制/语义对齐，不复制实现）。
///
/// 支持两种形态：
/// 1. `URL,{json 选项}`——选项键：method/headers/body/charset/type/retry/js/
///    webView/webJs/serverID/webViewDelayTime（webView 类仅识别不实现，
///    本应用无 WebView；type 记录透传，响应解析由内容嗅探决定）。
///    选项 JSON 兼容 Legado 单引号写法。
/// 2. 全 JS URL：`@js:` 或 `<js>…</js>`（可多段交错，`@result` 引用前段结果）。
///    求值顺序对齐 Legado initUrl：先 JS 段，再切 `,{json}` 选项，最后选项内
///    js 字段（result=已解析 URL，结果覆盖 URL）。
class UrlSpec {
  const UrlSpec({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.charset,
    this.type,
    this.retry = 0,
  });

  /// 选项剥离后的 URL（已过 JS 段求值与选项内 js 字段）。
  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final String? charset;
  final String? type;
  final int retry;

  bool get isPost => method == 'POST';
  bool get hasBody => body != null && body!.isNotEmpty;

  /// 选项 JSON 切分：首个两侧允许空白的逗号且后随 `{`（对齐 paramPattern
  /// `\s*,\s*(?=\{)`）。
  static final RegExp _optionSplit = RegExp(r'\s*,\s*(?=\{)');

  /// URL 中的 JS 段（`@js:` 到串尾 / `<js>…</js>`，大小写不敏感）。
  static final RegExp _jsSegment =
      RegExp(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)', caseSensitive: false);

  static bool containsJs(String raw) => _jsSegment.hasMatch(raw);

  /// 按 Legado analyzeJs 语义求值 URL 中的 JS 段：
  /// 段间文本以 `@result` 引用前段结果参与拼接，JS 结果成为新 result；
  /// 尾部非 JS 文本同样做 `@result` 拼接。无 JS 段原样返回。
  static Future<String> resolveJs(
    String raw,
    Future<String?> Function(String js, String result) eval,
  ) async {
    var result = raw;
    var start = 0;
    for (final match in _jsSegment.allMatches(raw)) {
      if (match.start > start) {
        final prefix = raw.substring(start, match.start).trim();
        if (prefix.isNotEmpty) {
          result = prefix.replaceAll('@result', result);
        }
      }
      final code = match.group(2) ?? match.group(1) ?? '';
      result = await eval(code, result) ?? '';
      start = match.end;
    }
    if (raw.length > start) {
      final tail = raw.substring(start).trim();
      if (tail.isNotEmpty) {
        result = tail.replaceAll('@result', result);
      }
    }
    return result;
  }

  /// 切出 URL 与选项 JSON；无选项返回 null。
  static ({String url, Map<String, dynamic> params})? splitOptions(String raw) {
    final match = _optionSplit.firstMatch(raw);
    if (match == null) return null;
    final url = raw.substring(0, match.start).trim();
    if (url.isEmpty || match.end >= raw.length) return null;
    final params = _decodeParams(raw.substring(match.end).trim());
    if (params == null) return null;
    return (url: url, params: params);
  }

  /// 完整解析。[evalJs] 为空时跳过 JS 段（原样保留）。
  /// 选项缺失/JSON 解析失败时退化为纯 GET URL（与 Legado GSON 失败容错一致）。
  static Future<UrlSpec> parse(
    String raw, {
    Future<String?> Function(String js, String result)? evalJs,
  }) async {
    var resolved = raw.trim();
    if (evalJs != null && containsJs(resolved)) {
      resolved = await resolveJs(resolved, evalJs);
    }
    final split = splitOptions(resolved);
    if (split == null) {
      return UrlSpec(url: resolved.trim());
    }
    final params = split.params;
    final method = (params['method']?.toString() ?? 'GET').trim().toUpperCase();
    final retryRaw = params['retry']?.toString().trim();
    var url = split.url;
    final jsOption = params['js']?.toString();
    if (evalJs != null && jsOption != null && jsOption.trim().isNotEmpty) {
      url = await evalJs(jsOption, url) ?? url;
    }
    return UrlSpec(
      url: url.trim(),
      method: method.isEmpty ? 'GET' : method,
      headers: _headersOf(params['headers']),
      body: params['body']?.toString(),
      charset: params['charset']?.toString(),
      type: params['type']?.toString(),
      retry: retryRaw == null || retryRaw.isEmpty ? 0 : int.tryParse(retryRaw) ?? 0,
    );
  }

  /// headers 选项：JSON 对象或「内容为 JSON 对象的字符串」→ 字符串表
  /// （对齐 UrlOption.getHeaderMap：值 toString）。
  static Map<String, String> _headersOf(dynamic value) {
    final Map<String, dynamic>? map;
    if (value is Map) {
      map = value.map((k, v) => MapEntry(k.toString(), v));
    } else if (value is String && value.trim().startsWith('{')) {
      map = _decodeParams(value);
    } else {
      map = null;
    }
    if (map == null) return const {};
    return {
      for (final entry in map.entries)
        if (entry.value != null) entry.key.toString(): entry.value.toString(),
    };
  }

  /// 选项 JSON：先标准双引号解析；失败退 Legado 单引号写法（盲替换），
  /// body 值含单引号时按失败处理（与现有搜索参数解析行为一致）。
  static Map<String, dynamic>? _decodeParams(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      try {
        final decoded = jsonDecode(jsonStr.replaceAll("'", '"'));
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        return null;
      }
    }
  }
}
