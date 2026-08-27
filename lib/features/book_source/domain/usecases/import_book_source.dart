import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:either_dart/either.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/network/url_redact.dart';
import '../entities/book_source.dart';
import '../repositories/book_source_repository.dart';
import 'parse_book_source_rule.dart';

/// 导入受限制（文件超限/下载超时）时抛出的专用异常，消息即用户可见文案。
/// 与普通网络失败区分：超限/超时给出明确提示，不再伪装成"网络请求失败: TimeoutException..."。
class ImportLimitExceeded implements Exception {
  final String message;
  const ImportLimitExceeded(this.message);

  @override
  String toString() => message;
}

/// 导入书源（支持 JSON 文件/网络链接/剪贴板）
class ImportBookSource {
  final BookSourceRepository repository;
  final ParseBookSourceRule parser;
  final DioClient _client;

  /// 空闲超时：下载停顿超过该时长判定挂起
  final Duration idleTimeout;
    /// 首字节超时：连接建立后超过该时长未收到任何数据判定服务器挂起。
    /// 必须大于 Dio 连接+重试最坏耗时（10s×4 + 退避 ≈ 46s），避免误杀合法重试。
    final Duration firstByteTimeout;
  /// 总时限：整个下载不能超过该时长
  final Duration totalLimit;
  /// 单个书源文件最大字节数，防止恶意/异常大文件耗尽内存
  static const int maxSourceBytes = 50 * 1024 * 1024;

  ImportBookSource({
    required this.repository,
    required this.parser,
    DioClient? client,
    this.idleTimeout = const Duration(seconds: 20),
        this.firstByteTimeout = const Duration(seconds: 60),
    this.totalLimit = const Duration(minutes: 10),
  }) : _client = client ?? DioClient();

  /// 从文件导入（支持单个书源 JSON 或书源列表 JSON 数组）
  Future<Either<String, List<BookSource>>> fromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: true,
      // 必需：IO 平台默认不读取文件内容，缺省时 file.bytes 恒为 null
      withData: true,
    );
    if (result == null) return const Left('未选择文件');

    final sources = <BookSource>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      final content = _decodeUtf8(bytes);
      final parsed = await _parseContent(content);
      parsed.fold((l) => null, (r) => sources.addAll(r));
    }
    if (sources.isEmpty) return const Left('未解析到有效书源');

    for (final source in sources) {
      await repository.save(source);
    }
    return Right(sources);
  }

  /// 从网络链接导入（支持单个书源 JSON 或书源列表 JSON 数组）。
  /// 采用"空闲超时"语义：只要持续收到数据就不中断（大文件/慢速源可完整下载），
  /// 停顿超过 [idleTimeout] 或超过 [totalLimit] 才判定失败。
  Future<Either<String, List<BookSource>>> fromUrl(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return const Left('请输入书源地址');
    debugPrint('[ImportBookSource] fromUrl 开始: ${redactUrl(trimmed)}');
    try {
      final content = await _downloadWithIdleTimeout(trimmed, onProgress: onProgress, cancelToken: cancelToken);
      debugPrint('[ImportBookSource] 请求完成, 内容长度: ${content.length}');
      return (await _parseContent(content)).fold(
        (error) => Left(error),
        (sources) async {
          for (final source in sources) {
            await repository.save(source);
          }
          return Right(sources);
        },
      );
    } on ImportLimitExceeded catch (e) {
      // 大小超限/下载超时：直接给出明确文案，不伪装成网络请求失败
      debugPrint('[ImportBookSource] 导入受限: ${e.message}');
      return Left(e.message);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return const Left('已取消下载');
      }
      debugPrint('[ImportBookSource] 请求失败: ${e.type}');
      return Left('网络请求失败: ${_friendlyError(e)}');
    } catch (e) {
      debugPrint('[ImportBookSource] 请求失败: ${e.runtimeType}');
      return Left('网络请求失败: $e');
    }
  }

  /// 空闲超时下载：有数据流入则持续等待，停顿超时或总时限到则失败
  Future<String> _downloadWithIdleTimeout(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    final completer = Completer<String>();
    final internalToken = CancelToken();
    cancelToken?.whenCancel.then((_) => internalToken.cancel());
    DateTime? lastActivity; // null = 尚未收到首字节，空闲计时未启动
    var sizeExceeded = false;
    late final Timer idleTimer;
    late final Timer totalTimer;
        late final Timer firstByteTimer;

    void finish() {
      idleTimer.cancel();
      totalTimer.cancel();
            firstByteTimer.cancel();
    }

    // 空闲检查周期：随 idleTimeout 自适应（1/4，限 100ms~3s），保证检测精度
    final checkInterval = Duration(
      milliseconds: (idleTimeout.inMilliseconds / 4).clamp(100, 3000).round(),
    );
    idleTimer = Timer.periodic(checkInterval, (_) {
      // 空闲窗口从首字节到达起算：连接/重试阶段不占空闲额度，
      // 避免慢服务器合法重试（最坏 ~46s）被 20s 空闲窗口误杀
      final activity = lastActivity;
      if (activity != null &&
          DateTime.now().difference(activity) > idleTimeout) {
        internalToken.cancel();
        finish();
        if (!completer.isCompleted) {
          completer.completeError(
            ImportLimitExceeded('下载中断：${idleTimeout.inSeconds} 秒无数据'),
          );
        }
      }
    });
        // 连接成功但服务器一直不发首字节：不受 Dio connectTimeout 约束，
        // 由首字节超时兜底（否则要等满 totalLimit）
        firstByteTimer = Timer(firstByteTimeout, () {
          if (lastActivity != null) return; // 已有数据流入，转交空闲计时
          internalToken.cancel();
          finish();
          if (!completer.isCompleted) {
            completer.completeError(
              ImportLimitExceeded('服务器 ${firstByteTimeout.inSeconds} 秒未发送数据'),
            );
          }
        });
    totalTimer = Timer(totalLimit, () {
      internalToken.cancel();
      finish();
      if (!completer.isCompleted) {
        completer.completeError(ImportLimitExceeded('下载超时（${totalLimit.inMinutes} 分钟上限）'));
      }
    });

    _client
        .getStringWithProgress(
          url,
          onProgress: (received, total) {
            lastActivity = DateTime.now();
            if (received > maxSourceBytes) {
              sizeExceeded = true;
              internalToken.cancel();
              finish();
              if (!completer.isCompleted) {
                completer.completeError(const ImportLimitExceeded('文件超过大小限制'));
              }
              return;
            }
            onProgress?.call(received, total);
          },
          cancelToken: internalToken,
        )
        .then((content) {
      finish();
      if (!completer.isCompleted) completer.complete(content);
    }).catchError((Object e) {
      finish();
      if (!completer.isCompleted) {
        if (sizeExceeded) {
          completer.completeError(const ImportLimitExceeded('文件超过大小限制'));
        } else {
          completer.completeError(e);
        }
      }
    });

    return completer.future;
  }

  /// 异常转友好提示（不含服务器细节）
  static String _friendlyError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '连接超时';
      case DioExceptionType.connectionError:
        return '无法连接服务器';
      case DioExceptionType.badResponse:
        return '服务器响应异常（${e.response?.statusCode}）';
      case DioExceptionType.cancel:
        return '已取消';
      default:
        return '请求失败';
    }
  }

  /// 从剪贴板导入
  Future<Either<String, List<BookSource>>> fromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data == null || data.text == null || data.text!.isEmpty) {
      return const Left('剪贴板为空');
    }
    return _parseContent(data.text!).fold(
      (l) => Left(l),
      (sources) async {
        for (final source in sources) {
          await repository.save(source);
        }
        return Right(sources);
      },
    );
  }

  static String _decodeUtf8(List<int> bytes) {
    final content = utf8.decode(bytes, allowMalformed: true);
    return content.startsWith('\uFEFF') ? content.substring(1) : content;
  }

  /// 解析内容（支持单个书源对象或书源数组）。
  /// 大文件数组解码下沉 worker isolate（compute），避免阻塞主 isolate；
  /// 逐项直接用已解码 Map 构建书源，不做 re-encode/re-decode。
  Future<Either<String, List<BookSource>>> _parseContent(String content) async {
    final text = content.trim();
    if (text.isEmpty) return const Left('内容为空');

    // 尝试解析为数组
    if (text.startsWith('[')) {
      try {
        final list = text.length > _isolateDecodeThreshold
            ? await compute(_decodeArrayJson, text)
            : (jsonDecode(text) as List);
        final sources = <BookSource>[];
        final seen = <String>{};
        for (final item in list) {
          if (item is! Map) continue;
          final parsed =
              parser.executeMap(Map<String, dynamic>.from(item));
          parsed.fold((l) => null, (r) {
            // 按 URL 去重：同一书源重复导入不累积（无 URL 时按稳定 id）
            final key = r.bookSourceUrl?.trim().toLowerCase() ?? r.id;
            if (seen.add(key)) sources.add(r);
          });
        }
        if (sources.isEmpty) return const Left('未解析到有效书源');
        return Right(sources);
      } catch (e) {
        return Left('书源格式错误: $e');
      }
    }

    // 单个书源对象
    final parsed = parser.execute(text);
    return parsed.fold(
      (l) => Left(l),
      (r) => Right([r]),
    );
  }
}

/// 单个书源 JSON 超过该长度（字节）时，数组解码下沉 worker isolate。
/// 常见书源列表几百 KB，isolate 往返开销不值得；21MB 级大列表驻留主 isolate
/// 会阻塞 UI 数秒。
const int _isolateDecodeThreshold = 1024 * 1024;

/// 在 worker isolate 中解码书源 JSON 数组（compute 要求顶层函数）
List<dynamic> _decodeArrayJson(String text) => jsonDecode(text) as List;
