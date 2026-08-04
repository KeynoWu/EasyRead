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
    final box = await Hive.openBox<String>(_boxName);
    await box.put('config', jsonEncode({
      'url': config.url,
      'username': config.username,
    }));
    // 密码写入安全存储失败时抛出，由调用方提示（避免用户误以为密码已保存）
    await _secureStorage.write(key: _passwordKey, value: config.password);
  }

  Dio _dio(WebDavConfig config) {
    return Dio(BaseOptions(
      baseUrl: config.url,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Authorization': 'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
      },
    ));
  }

  /// 上传备份到 WebDAV
  Future<String?> upload(String backupJson) async {
    final config = await loadConfig();
    if (!config.isConfigured) return '未配置 WebDAV';
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
    if (!config.isConfigured) return '未配置 WebDAV';
    try {
      final response = await _dio(config).get(_fileName);
      return response.data.toString();
    } catch (e) {
      return '下载失败: ${_friendlyError(e)}';
    }
  }

  /// 测试连接
  Future<String?> testConnection() async {
    final config = await loadConfig();
    if (!config.isConfigured) return '未配置 WebDAV';
    try {
      await _dio(config).get('');
      return null;
    } catch (e) {
      return '连接失败: ${_friendlyError(e)}';
    }
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
