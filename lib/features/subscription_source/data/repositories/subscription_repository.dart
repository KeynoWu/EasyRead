import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../../domain/entities/rss_entry.dart';
import '../../domain/entities/subscription_source.dart';
import '../services/rss_parser.dart';
import '../services/subscription_source_service.dart';

/// 拉取订阅源的结构化结果：成功携带条目，失败携带分类错误信息。
class SubscriptionFetchResult {
  /// 成功时解析出的条目；失败时为空列表。
  final List<RssEntry> entries;

  /// 失败原因；null 表示成功。
  final String? error;

  const SubscriptionFetchResult._(this.entries, this.error);

  const SubscriptionFetchResult.success(List<RssEntry> entries)
      : this._(entries, null);

  const SubscriptionFetchResult.failure(String error)
      : this._(const [], error);

  bool get isSuccess => error == null;

  /// 成功时解析出的条目数。
  int get entryCount => entries.length;
}

/// 订阅源网络仓库：经 DioClient 拉取 XML → RssParser 解析 → 更新 lastUpdatedAt。
///
/// 错误分类：网络错误 / 地址不合法（SSRF 防护拦截）/ 解析失败 / 空源。
/// 所有网络请求复用 DioClient（内置 10s 连接超时、15s 接收超时、
/// SSRF 防护与重定向安全处理），不新增网络通道。
class SubscriptionRepository {
  final DioClient dio;
  final SubscriptionSourceService service;

  SubscriptionRepository({DioClient? dio, SubscriptionSourceService? service})
      : dio = dio ?? DioClient(),
        service = service ?? SubscriptionSourceService();

  /// 拉取并解析订阅源，成功后更新 lastUpdatedAt。
  Future<SubscriptionFetchResult> fetchEntries(SubscriptionSource source) async {
    final String xml;
    try {
      xml = await dio.getString(source.url);
    } on DioException catch (e) {
      return SubscriptionFetchResult.failure('网络请求失败：${_describeDioError(e)}');
    } on ArgumentError catch (e) {
      // DioClient 对非 http/https 或内网地址抛 ArgumentError
      return SubscriptionFetchResult.failure('地址不合法：${e.message}');
    } on Exception {
      return const SubscriptionFetchResult.failure('网络请求失败');
    } catch (_) {
      // 兜底：Error 子类（如重定向耗尽的 StateError）也不外泄，
      // 页面直接 await 无 try/catch，未处理异步异常会崩 UI
      return const SubscriptionFetchResult.failure('网络请求失败');
    }

    final entries = RssParser.tryParse(xml, sourceName: source.name);
    if (entries == null) {
      return const SubscriptionFetchResult.failure('订阅源解析失败：不是有效的 RSS/Atom 文档');
    }

    await service.updateLastUpdatedAt(source.id, DateTime.now());
    if (entries.isEmpty) {
      return const SubscriptionFetchResult.failure('订阅源没有可显示的条目');
    }
    return SubscriptionFetchResult.success(entries);
  }

  static String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '请求超时';
      case DioExceptionType.connectionError:
        return '无法连接服务器';
      case DioExceptionType.badResponse:
        return '服务器响应异常（HTTP ${e.response?.statusCode ?? '?'}）';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badCertificate:
        return '证书校验失败';
      default:
        return e.message ?? '未知错误';
    }
  }
}
