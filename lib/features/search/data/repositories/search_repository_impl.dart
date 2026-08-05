import 'dart:convert';
import 'package:dio/dio.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/search_repository.dart';
import '../engines/rule_engine.dart';

class SearchRepositoryImpl implements SearchRepository {
  final DioClient _client;

  /// 登录 Cookie 会话缓存 TTL：命中缓存直接复用，跳过重复 login 请求
  static const Duration _cookieTtl = Duration(minutes: 30);

  /// 按 sourceId 缓存的登录 Cookie 会话
  final Map<String, _CookieSession> _cookieCache = {};

  SearchRepositoryImpl({DioClient? client})
      : _client = client ?? DioClient();

  @override
  Future<List<SearchResult>> searchWithSource(String keyword, BookSource source, {CancelToken? cancelToken}) async {
    if (!source.enabled || source.searchUrl == null || source.bookListRule == null) {
      return [];
    }

    try {
      final url = source.searchUrl!.replaceAll('{{key}}', Uri.encodeComponent(keyword));
      final headers = <String, String>{...source.requestHeaders};
      if (source.loginUrl != null &&
          source.loginUrl!.isNotEmpty &&
          !headers.containsKey('Cookie')) {
        final cached = _cookieCache[source.id];
        if (cached != null && cached.isValid) {
          // 会话未过期：复用缓存 Cookie，跳过重复 login 请求
          headers['Cookie'] = cached.cookie;
        } else {
          try {
            final loginHeaders = await _client.getResponseHeaders(
              source.loginUrl!,
              headers: headers.isEmpty ? null : headers,
              sourceId: source.id,
              cancelToken: cancelToken,
            );
            final setCookies = loginHeaders['set-cookie'] ?? const [];
            if (setCookies.isNotEmpty) {
              final cookie = setCookies
                  .map((value) => value.split(';').first)
                  .join('; ');
              headers['Cookie'] = cookie;
              _cookieCache[source.id] = _CookieSession(cookie);
            }
          } catch (_) {
            // 登录失败时仍尝试直接搜索，避免单个书源拖垮聚合搜索
          }
        }
      }
      final html = await _client.getString(
        url,
        headers: headers.isEmpty ? null : headers,
        sourceId: source.id,
        cancelToken: cancelToken,
      );

      final items = RuleEngine.extractElements(html, source.bookListRule);
      final results = <SearchResult>[];

      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item == null) continue;

        final name = RuleEngine.getElementText(item, source.bookNameRule);
        if (name == null || name.isEmpty) continue;

        final detailUrl = RuleEngine.getElementText(item, source.bookDetailUrlRule);
        results.add(SearchResult(
          bookId: _stableBookId(source.id, detailUrl, i),
          name: name,
          author: RuleEngine.getElementText(item, source.bookAuthorRule),
          coverUrl: RuleEngine.getElementText(item, source.coverUrlRule),
          detailUrl: detailUrl,
          sourceId: source.id,
          sourceName: source.name,
        ));
      }

      return results;
    } catch (e) {
      // 主动取消（换词时中断旧批次）不视为错误：返回空结果，
      // 避免上层把取消误报为搜索失败
      if (e is DioException && e.type == DioExceptionType.cancel) return [];
      return [];
    }
  }

  /// 基于详情 URL 生成稳定书 ID：同一本书在不同搜索中保持同一 ID，
  /// 避免列表索引变化导致缓存与阅读进度错位。
  static String _stableBookId(String sourceId, String? detailUrl, int index) {
    if (detailUrl != null && detailUrl.isNotEmpty) {
      return '${sourceId}_${base64Url.encode(utf8.encode(detailUrl))}';
    }
    return '${sourceId}_$index';
  }
}

/// 登录 Cookie 会话缓存条目：记录抓取时间，TTL 过期后重新登录
class _CookieSession {
  final String cookie;
  final DateTime fetchedAt;

  _CookieSession(this.cookie) : fetchedAt = DateTime.now();

  bool get isValid => DateTime.now().difference(fetchedAt) < SearchRepositoryImpl._cookieTtl;
}
