import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import '../entities/webdav_config.dart';

/// WebDAV 云同步服务
class WebDavSync {
  static const String _boxName = 'webdav_config';
  static const String _fileName = 'easyread_backup.json';
  static const String _passwordKey = 'webdav_password';

  /// 密码经平台安全存储（iOS Keychain / Android Keystore）保存
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  WebDavConfig getConfig() {
    // 同步读取仅用于界面回显；box 未打开时返回空配置而非崩溃
    if (!Hive.isBoxOpen(_boxName)) return const WebDavConfig();
    final box = Hive.box<String>(_boxName);
    final data = box.get('config');
    if (data == null) return const WebDavConfig();
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      return WebDavConfig(
        url: map['url']?.toString() ?? '',
        username: map['username']?.toString() ?? '',
        password: '',
      );
    } catch (_) {
      return const WebDavConfig();
    }
  }

  /// 完整配置（含安全存储中的密码），网络操作使用
  Future<WebDavConfig> loadConfig() async {
    final base = getConfig();
    String password = '';
    try {
      password = await _secureStorage.read(key: _passwordKey) ?? '';
    } catch (_) {
      // 安全存储不可用时降级为空密码
    }
    return WebDavConfig(
      url: base.url,
      username: base.username,
      password: password,
    );
  }

  Future<void> saveConfig(WebDavConfig config) async {
    if (!_isAllowedWebDavUrl(config.url)) {
      throw ArgumentError('WebDAV 地址必须使用 HTTPS（本机测试可允许 localhost HTTP）');
    }
    final box = await Hive.openBox<String>(_boxName);
    await box.put('config', jsonEncode({
      'url': config.url,
      'username': config.username,
    }));
    // 密码写入安全存储失败时抛出，由调用方提示（避免用户误以为密码已保存）
    await _secureStorage.write(key: _passwordKey, value: config.password);
  }

  Dio _dio(WebDavConfig config) {
    final baseUri = Uri.parse(config.url);
    final dio = Dio(BaseOptions(
      // 无尾斜杠的 baseUrl 拼接相对路径会丢失最后一段（https://host/dav + file → https://host/file）
      baseUrl: _normalizeBaseUrl(config.url),
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Authorization': 'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
      },
    ));
    // 重定向防护：Dio 跟随跨域 3xx 时会带着 Basic Authorization 头到新域，
    // 造成凭据泄露。onRequest 在每次重定向跳转时都会重新触发，
    // 此处对离开 baseUrl 所在域的目标清除 Authorization（与主网络层
    // DioClient._sanitizeRedirectHeaders 的策略一致）。
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      final reqHost = options.uri.host.toLowerCase();
      final baseHost = baseUri.host.toLowerCase();
      if (reqHost != baseHost) {
        options.headers.remove('Authorization');
      }
      handler.next(options);
    }));
    return dio;
  }

  /// 规范化 baseUrl：确保以 / 结尾，避免相对路径拼接丢失路径段
  static String _normalizeBaseUrl(String url) {
    final trimmed = url.trim();
    return trimmed.endsWith('/') ? trimmed : '$trimmed/';
  }

  /// 上传备份到 WebDAV
  Future<String?> upload(String backupJson) async {
    final config = await loadConfig();
    final configError = _configError(config);
    if (configError != null) return configError;
    try {
      await _dio(config).put(
        _fileName,
        data: backupJson,
        options: Options(contentType: 'application/json'),
      );
      return null;
    } catch (e) {
      return '上传失败: ${_friendlyError(e)}';
    }
  }

  /// 从 WebDAV 下载备份
  Future<String?> download() async {
    final config = await loadConfig();
    final configError = _configError(config);
    if (configError != null) return configError;
    try {
      final response = await _dio(config).get(
        _fileName,
        options: Options(responseType: ResponseType.plain),
      );
      return response.data.toString();
    } catch (e) {
      return '下载失败: ${_friendlyError(e)}';
    }
  }

  /// 用指定配置测试连接（表单未保存时也能测试当前输入）
  Future<String?> testConnectionWith(WebDavConfig config) async {
    final configError = _configError(config);
    if (configError != null) return configError;
    try {
      await _dio(config).get('');
      return null;
    } catch (e) {
      return '连接失败: ${_friendlyError(e)}';
    }
  }

  static bool _isAllowedWebDavUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme == 'https') return true;
    if (uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1')) {
      return true;
    }
    return false;
  }

  static String? _configError(WebDavConfig config) {
    if (!config.isConfigured) return '未配置 WebDAV';
    if (!_isAllowedWebDavUrl(config.url)) {
      return 'WebDAV 地址必须使用 HTTPS';
    }
    return null;
  }

  /// 将异常转换为不含服务器细节的友好提示，避免泄露状态码与响应体
  static String _friendlyError(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '连接超时';
        case DioExceptionType.connectionError:
          return '无法连接服务器';
        case DioExceptionType.badResponse:
          return '服务器响应异常';
        default:
          return '请求失败';
      }
    }
    return '未知错误';
  }
}
