import '../../../search/domain/entities/search_result.dart';

/// 书源调试结果：原始响应片段 + 规则解析出的示例结果。
class BookSourceDebugResult {
  final String? rawHtml;
  final List<SearchResult> results;
  final String? error;

  const BookSourceDebugResult({
    this.rawHtml,
    this.results = const [],
    this.error,
  });

  bool get success => error == null;
}
