import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../data/cookie_jar_service.dart';
import 'interceptors/rate_limit_interceptor.dart';
import 'interceptors/retry_interceptor.dart';
import 'interceptors/ua_interceptor.dart';

/// 全局 Dio 客户端 — 单例，所有网络请求通过此实例
class DioClient {
  static DioClient? _instance;
  final Dio _dio;

  DioClient._() : _dio = _buildDio();

  DioClient._withDio(Dio dio) : _dio = dio;

  @visibleForTesting
  DioClient.forTesting(Dio dio) : this._withDio(dio);

  static Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
        headers: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      ),
    );
    dio.interceptors.addAll([
      UaInterceptor(),
      RateLimitInterceptor(),
      RetryInterceptor(dio),
    ]);
    return dio;
  }

  factory DioClient() {
    _instance ??= DioClient._();
    return _instance!;
  }

  Dio get dio => _dio;

  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return _decodeBody(response.data, charset, contentType: _contentTypeOf(response));
  }

  /// 二进制获取（封面/正文图片防盗链场景：带书源 headers/cookie 走
  /// 完整 _send 管线——SSRF 每跳校验、Set-Cookie 回写、限流重试）。
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    final data = response.data;
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    return Uint8List(0);
  }

  /// 请求并返回（body, 响应头, statusCode）——JS 桥 java.connect 需要
  /// 完整 StrResponse（Legado JsExtensions.connect 语义）
  Future<(String, Map<String, List<String>>, int)> getResponse(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return (
      _decodeBody(response.data, charset, contentType: _contentTypeOf(response)),
      response.headers.map,
      response.statusCode ?? 0,
    );
  }

  /// 请求并返回响应头，用于书源登录后捕获 Set-Cookie。
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    final response = await _get(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      cancelToken: cancelToken,
    );
    return response.headers.map;
  }

  /// 带下载进度回调的请求（大文件场景使用）
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final response = await _send(
      'GET',
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      extra: extra,
      responseType: ResponseType.bytes,
      // 大文件下载的空闲判定由 ImportBookSource 控制，
      // 这里用 Duration.zero 禁用 Dio 固定 receiveTimeout，避免其先于上层超时生效。
      receiveTimeout: Duration.zero,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    return _decodeBody(response.data, charset, contentType: _contentTypeOf(response));
  }

  /// POST 表单请求（Legado 书源搜索等场景）。
  /// [charset] 指定响应编码（gbk 等），默认 UTF-8。
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    final response = await _send(
      'POST',
      url,
      headers: {
        ...?headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: body,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return _decodeBody(response.data, charset, contentType: _contentTypeOf(response));
  }

  /// POST 表单请求并返回响应头（书源登录等场景，部分接口需 POST 才能 Set-Cookie）
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    final response = await _send(
      'POST',
      url,
      headers: {
        ...?headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: body,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return response.headers.map;
  }

  /// POST 表单请求并同时返回（body, 响应头）——JS 桥 java.post 需要两者
  /// （Legado JsExtensions.post 返回完整 Response）。
  Future<(String, Map<String, List<String>>)> postFormFull(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    final response = await _send(
      'POST',
      url,
      headers: {
        ...?headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      data: body,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
    );
    return (_decodeBody(response.data, charset, contentType: _contentTypeOf(response)), response.headers.map);
  }

  /// 从响应头提取 content-type 值（decode 用）
  static String? _contentTypeOf(Response<dynamic> response) {
    final values = response.headers['content-type'];
    if (values == null || values.isEmpty) return null;
    return values.join('; ');
  }

  /// 通用取文本请求（GET 或带 body 的 POST）——URL,{json} 选项接入
  /// 目录/正文/搜索的统一入口。[retry] 对齐 Legado AnalyzeUrl retry 选项：
  /// 失败后重试 N 次（0=不重试）。POST 默认表单 Content-Type，
  /// 显式 headers 里的 Content-Type 优先（JSON body 源自带声明）。
  Future<String> requestString(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    int retry = 0,
    CancelToken? cancelToken,
  }) async {
    final isPost = method.trim().toUpperCase() == 'POST';
    var attempt = 0;
    while (true) {
      try {
        final response = await _send(
          isPost ? 'POST' : 'GET',
          url,
          headers: isPost
              ? {
                  ...?headers,
                  'Content-Type': headers?['Content-Type'] ??
                      'application/x-www-form-urlencoded',
                }
              : headers,
          data: isPost ? body : null,
          sourceId: sourceId,
          concurrentRate: concurrentRate,
          responseType: ResponseType.bytes,
          cancelToken: cancelToken,
        );
        return _decodeBody(
          response.data,
          charset,
          contentType: _contentTypeOf(response),
        );
      } on DioException catch (e) {
        // 重试仅对瞬时网络异常（对齐 Legado retry 的 IOException 语义）：
        // cancel 是调用方主动停止，重发违背取消意图；解码等非网络错误
        // 重试也不会好转，直接抛。
        if (e.type == DioExceptionType.cancel ||
            !_isRetryableNetworkError(e)) {
          rethrow;
        }
        attempt++;
        if (attempt > retry) rethrow;
      }
    }
  }

  /// 是否可重试的网络异常（连接/读写超时、连接失败、证书问题）；
  /// 服务器已响应（badResponse）不重试——重试同样的请求大概率同样失败。
  static bool _isRetryableNetworkError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        return true;
      default:
        return false;
    }
  }

  /// 按 charset 解码响应字节（P1-12，三级检测对齐 Legado OkHttpUtils）：
  /// 规则 charset（书源显式指定）→ Content-Type 头 charset → UTF-8 兜底；
  /// 自动剥离 UTF-8/UTF-16 BOM。
  static String _decodeBody(
    dynamic data,
    String? charset, {
    String? contentType,
  }) {
    // 仅接受字节列表；异常类型不产出噪音文本
    if (data is! List<int>) return '';
    var bytes = data;
    // BOM 检测与剥离：UTF-8 EF BB BF / UTF-16 LE FF FE / UTF-16 BE FE FF。
    // UTF-16 站点必须按 UTF-16 解码（仅剥 BOM 会 mojibake）。
    var utf16LittleEndian = false;
    var hasUtf16Bom = false;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      bytes = bytes.sublist(3);
    } else if (bytes.length >= 2 &&
        (bytes[0] == 0xFF && bytes[1] == 0xFE)) {
      bytes = bytes.sublist(2);
      hasUtf16Bom = true;
      utf16LittleEndian = true;
    } else if (bytes.length >= 2 &&
        (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
      bytes = bytes.sublist(2);
      hasUtf16Bom = true;
      utf16LittleEndian = false;
    }
    // 规则 charset 优先；其次 Content-Type 头的 charset 参数
    var effective = charset?.trim();
    if (effective == null || effective.isEmpty) {
      final ct = contentType?.toLowerCase() ?? '';
      final m = RegExp(r'charset\s*=\s*([\w-]+)').firstMatch(ct);
      if (m != null) effective = m.group(1);
    }
    final lower = effective?.toLowerCase();
    // UTF-16：BOM 优先定端序；无 BOM 时按 RFC 2781 默认大端
    //（显式 utf-16le/be 覆盖）
    if (hasUtf16Bom || lower == 'utf-16' || lower == 'utf16') {
      return _utf16Decode(bytes, utf16LittleEndian);
    }
    if (lower == 'utf-16le' || lower == 'utf16le') {
      return _utf16Decode(bytes, true);
    }
    if (lower == 'utf-16be' || lower == 'utf16be') {
      return _utf16Decode(bytes, false);
    }
    if (lower == 'gbk' || lower == 'gb2312' || lower == 'gb18030') {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // GBK 解码失败回退 UTF-8
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// UTF-16 字节解码（LE/BE）。Dart String 即 UTF-16 码元序列：
  /// 逐码元还原可保留代理对（含非成对代理，不丢字）。
  static String _utf16Decode(List<int> bytes, bool littleEndian) {
    final buffer = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final unit = littleEndian
          ? (bytes[i] | (bytes[i + 1] << 8))
          : ((bytes[i] << 8) | bytes[i + 1]);
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  Future<Response<dynamic>> _get(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    Map<String, dynamic>? extra,
    ResponseType? responseType,
    Duration? receiveTimeout,
    void Function(int received, int total)? onReceiveProgress,
    CancelToken? cancelToken,
  }) {
    return _send(
      'GET',
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      extra: extra,
      responseType: responseType,
      receiveTimeout: receiveTimeout,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  /// 通用请求：重定向安全处理（SSRF 每跳校验 / 禁 HTTPS 降级 / 跨域清敏感头 / 上限 5 跳）
  Future<Response<dynamic>> _send(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? sourceId,
    String? concurrentRate,
    Map<String, dynamic>? extra,
    ResponseType? responseType,
    Duration? receiveTimeout,
    void Function(int received, int total)? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    var current = url;
    var activeHeaders = headers;
    var currentUri = Uri.parse(current);
    for (var i = 0; i < 5; i++) {
      await _assertSafeUrl(current);
      final options = Options(
        headers: activeHeaders,
        extra: {
          'source_id': sourceId,
          'concurrent_rate': ?concurrentRate,
          ...?extra,
        },
        responseType: responseType ?? ResponseType.json,
        receiveTimeout: receiveTimeout,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      );
      final response = method == 'POST'
          ? await _dio.post<dynamic>(
              current,
              data: data,
              options: options,
              onReceiveProgress: onReceiveProgress,
              cancelToken: cancelToken,
            )
          : await _dio.get<dynamic>(
              current,
              options: options,
              onReceiveProgress: onReceiveProgress,
              cancelToken: cancelToken,
            );
      // 响应 Set-Cookie 全局回写（P0-11）：带 sourceId 的请求逐跳捕获，
      // 按名合并进书源 cookie 盒（Legado CookieManager 语义）——修复
      // 会话轮换后登录态静默衰减。失败不影响响应本身。
      if (sourceId != null && sourceId.isNotEmpty) {
        final setCookies = response.headers['set-cookie'];
        if (setCookies != null && setCookies.isNotEmpty) {
          try {
            await CookieJarService().absorb(sourceId, setCookies);
          } catch (_) {
            // cookie 盒不可用（未初始化/损坏）时静默跳过
          }
        }
      }
      final statusCode = response.statusCode ?? 0;
      final location = response.headers.value('location');
      if (statusCode >= 300 && statusCode < 400) {
        if (location == null || location.isEmpty) return response;
        final nextUri = currentUri.resolve(location);
        if (currentUri.scheme == 'https' && nextUri.scheme == 'http') {
          // 部分站点（移动站）用 http 重定向：允许降级，但必须清除
          // Cookie/Authorization 等敏感头，避免凭据明文泄露（MITM 面）
          activeHeaders = _sanitizeRedirectHeaders(activeHeaders);
        }
        if (nextUri.scheme != currentUri.scheme ||
            nextUri.host.toLowerCase() != currentUri.host.toLowerCase() ||
            nextUri.port != currentUri.port) {
          activeHeaders = _sanitizeRedirectHeaders(activeHeaders);
        }
        // HTTP 语义：301/302/303 重定向后 POST 应转为 GET 并丢弃 body；
        // 仅 307/308 保持原方法与 body
        if (statusCode == 301 || statusCode == 302 || statusCode == 303) {
          method = 'GET';
          data = null;
          // 转 GET 后无 body：移除表单 Content-Type，避免无 body 仍声明
          // application/x-www-form-urlencoded 引起严格代理/服务端告警
          if (activeHeaders != null &&
              activeHeaders.containsKey('Content-Type')) {
            activeHeaders = Map<String, String>.from(activeHeaders)
              ..remove('Content-Type');
            if (activeHeaders.isEmpty) activeHeaders = null;
          }
        }
        current = nextUri.toString();
        currentUri = nextUri;
        continue;
      }
      return response;
    }
    throw StateError('重定向次数过多');
  }

  /// 校验 URL 安全：scheme 合法 + 非内网/保留地址；对域名额外做 DNS 解析，
  /// 逐条校验解析出的 IP，封堵 nip.io / localtest.me / DNS 重绑定等绕过手段。
  /// 解析失败时放行（让真实请求在传输层失败）：不影响离线/无 DNS 环境，
  /// 但一旦解析成功且指向内网/保留地址即拒绝。
  static Future<void> _assertSafeUrl(String url) async {
    if (!_isHttpUrl(url)) {
      throw ArgumentError('不支持的 URL scheme 或地址: $url');
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final host = uri.host.toLowerCase();
    // 字面量 IP / 数字型 host 已在 _isHttpUrl 中处理完毕，无需解析
    if (_parseIpv4(host) != null ||
        host.contains(':') ||
        _looksLikeNumericHost(host)) {
      return;
    }
    try {
      final addresses = await InternetAddress.lookup(host);
      for (final address in addresses) {
        if (!_isSafeResolvedAddress(address)) {
          throw ArgumentError('域名解析到内网/保留地址，拒绝请求: $url');
        }
      }
    } catch (e) {
      // 仅吞掉 DNS 解析类错误（SocketException 等）：请求随后会在传输层失败。
      // 已解析出不安全地址时上面已抛出 ArgumentError，不会被此处吞掉。
      if (e is ArgumentError) rethrow;
      return;
    }
  }

  static bool _isSafeResolvedAddress(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      final bytes = address.rawAddress;
      if (bytes.length != 4) return false;
      return !_isUnsafeIpv4([bytes[0], bytes[1], bytes[2], bytes[3]]);
    }
    return !_isUnsafeIpv6(address.address);
  }

  /// 仅允许 http/https，并阻止直接指向本机、内网和保留地址的 URL。
  static bool _isHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty || host == 'localhost' || host == '::1') return false;
    if (host.startsWith('127.')) return false;
    final ipv4 = _parseIpv4(host);
    if (ipv4 != null) return !_isUnsafeIpv4(ipv4);
    if (host.contains(':')) return !_isUnsafeIpv6(host);
    // 非标准 IP 表示（简写/八进制/十六进制/十进制整数），系统解析器会还原为
    // 私网/回环地址（如 127.1 → 127.0.0.1、2130706433 → 127.0.0.1），一律拒绝。
    if (_looksLikeNumericHost(host)) return false;
    return true;
  }

  /// 形如纯数字/点分数字/十六进制整数的 host，视为可疑的非标准 IP 表示。
  static bool _looksLikeNumericHost(String host) {
    if (RegExp(r'^[0-9]+(\.[0-9]+)*$').hasMatch(host)) return true;
    return RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(host);
  }

  static bool _isUnsafeIpv4(List<int> ipv4) {
    if (ipv4[0] == 0 || ipv4[0] == 10 || ipv4[0] == 127) return true;
    if (ipv4[0] == 172 && ipv4[1] >= 16 && ipv4[1] <= 31) return true;
    if (ipv4[0] == 192 && ipv4[1] == 168) return true;
    if (ipv4[0] == 169 && ipv4[1] == 254) return true;
    // CGNAT 100.64.0.0/10 与 benchmark 198.18.0.0/15：非公网可达的保留段
    if (ipv4[0] == 100 && ipv4[1] >= 64 && ipv4[1] <= 127) return true;
    if (ipv4[0] == 198 && (ipv4[1] == 18 || ipv4[1] == 19)) return true;
    return ipv4[0] >= 224;
  }

  static bool _isUnsafeIpv6(String host) {
    final lower = host.replaceAll('[', '').replaceAll(']', '');
    if (lower == '::1') return true;
    if (lower.startsWith('::ffff:')) {
      final tail = lower.substring(7);
      // 点分十进制映射：::ffff:127.0.0.1
      final ipv4 = _parseIpv4(tail);
      if (ipv4 != null) return _isUnsafeIpv4(ipv4);
      // 十六进制对映射：::ffff:7f00:1（= 127.0.0.1）
      final parts = tail.split(':');
      if (parts.length == 2) {
        final mapped = _ipv4FromHexPair(parts[0], parts[1]);
        if (mapped != null) return _isUnsafeIpv4(mapped);
      }
    }
    // 完整 8 组 IPv6（Dart Uri 不压缩，需显式处理）：
    // IPv4 映射 0:0:0:0:0:ffff:<v4> 与回环 0:0:0:0:0:0:0:1
    if (lower.contains(':') && !lower.contains('::')) {
      final groups = lower.split(':');
      if (groups.length >= 7 &&
          groups.take(5).every((g) => g == '0') &&
          groups[5] == 'ffff') {
        List<int>? mapped;
        if (groups.length == 8) {
          mapped = _ipv4FromHexPair(groups[6], groups[7]);
        } else if (groups.length == 7) {
          mapped = _parseIpv4(groups[6]);
        }
        if (mapped != null) return _isUnsafeIpv4(mapped);
      }
      if (groups.length == 8 &&
          groups.take(7).every((g) => g == '0') &&
          groups[7] == '1') {
        return true; // ::1 完整形式
      }
    }
    if (lower.startsWith('::')) {
      final ipv4 = _parseIpv4(lower.substring(2));
      if (ipv4 != null) return _isUnsafeIpv4(ipv4);
    }
    if (lower.startsWith('fc') || lower.startsWith('fd')) return true;
    if (lower.startsWith('fe8') ||
        lower.startsWith('fe9') ||
        lower.startsWith('fea') ||
        lower.startsWith('feb')) {
      return true;
    }
    return false;
  }

  /// 将两个十六进制组（各 0~FFFF）拼成 IPv4 地址
  static List<int>? _ipv4FromHexPair(String hiHex, String loHex) {
    final hi = int.tryParse(hiHex, radix: 16);
    final lo = int.tryParse(loHex, radix: 16);
    if (hi == null || lo == null || hi > 0xFFFF || lo > 0xFFFF) return null;
    return [hi >> 8, hi & 0xFF, lo >> 8, lo & 0xFF];
  }

  static Map<String, String>? _sanitizeRedirectHeaders(
    Map<String, String>? headers,
  ) {
    if (headers == null) return null;
    // content-type 为非敏感请求头：跨域重定向后仍可能以 POST 重发 body（307/308）
    const allowed = {
      'accept',
      'accept-language',
      'user-agent',
      'accept-encoding',
      'connection',
      'content-type',
    };
    final sanitized = <String, String>{};
    for (final entry in headers.entries) {
      if (allowed.contains(entry.key.toLowerCase())) {
        sanitized[entry.key] = entry.value;
      }
    }
    return sanitized.isEmpty ? null : sanitized;
  }

  static List<int>? _parseIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final result = <int>[];
    for (final part in parts) {
      // 前导零是八进制表示（如 0177 = 127.0.0.1），非标准点分十进制。
      // 拒绝按 IP 解析，使其落入 _looksLikeNumericHost 被拦截。
      if (part.length > 1 && part.startsWith('0')) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      result.add(value);
    }
    return result;
  }
}
