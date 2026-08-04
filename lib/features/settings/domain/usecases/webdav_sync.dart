import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import '../entities/webdav_config.dart';

/// WebDAV 云同步服务
class WebDavSync {
  static const String _boxName = 'webdav_config';
  static const String _fileName = 'easyread_backup.json';

  WebDavConfig getConfig() {
    final box = Hive.box<String>(_boxName);
    final data = box.get('config');
    if (data == null) return const WebDavConfig();
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      return WebDavConfig(
        url: map['url']?.toString() ?? '',
        username: map['username']?.toString() ?? '',
        password: map['password']?.toString() ?? '',
      );
    } catch (_) {
      return const WebDavConfig();
    }
  }

  Future<void> saveConfig(WebDavConfig config) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.put('config', jsonEncode({
      'url': config.url,
      'username': config.username,
      'password': config.password,
    }));
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
    final config = getConfig();
    if (!config.isConfigured) return '未配置 WebDAV';
    try {
      await _dio(config).put(
        _fileName,
        data: backupJson,
        options: Options(contentType: 'application/json'),
      );
      return null;
    } catch (e) {
      return '上传失败: $e';
    }
  }

  /// 从 WebDAV 下载备份
  Future<String?> download() async {
    final config = getConfig();
    if (!config.isConfigured) return '未配置 WebDAV';
    try {
      final response = await _dio(config).get(_fileName);
      return response.data.toString();
    } catch (e) {
      return '下载失败: $e';
    }
  }

  /// 测试连接
  Future<String?> testConnection() async {
    final config = getConfig();
    if (!config.isConfigured) return '未配置 WebDAV';
    try {
      await _dio(config).get('');
      return null;
    } catch (e) {
      return '连接失败: $e';
    }
  }
}
