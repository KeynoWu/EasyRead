import 'package:dio/dio.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../entities/search_result.dart';

abstract class SearchRepository {
  /// 使用书源配置执行搜索（单源）。返回原始结果，由用例层负责聚合去重。
  /// [cancelToken] 非空时透传给底层网络请求，供上层换词时取消旧批次。
  /// [page] 非空时替换搜索 URL/body 中的 `{{page}}`（Legado 搜索分页）。
  Future<List<SearchResult>> searchWithSource(
    String keyword,
    BookSource source, {
    int? page,
    CancelToken? cancelToken,
    bool throwOnError = false,
  });

  /// 使用书源发现/榜单 URL 拉取书籍列表。
  Future<List<SearchResult>> exploreWithSource(
    BookSource source,
    String url, {
    int? page,
    CancelToken? cancelToken,
    bool throwOnError = false,
  });
}
