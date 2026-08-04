import '../../../search/data/repositories/search_repository_impl.dart';
import '../../../search/domain/repositories/search_repository.dart';
import '../entities/book_source.dart';

/// 书源校验结果
class BookSourceTestResult {
  final bool success;
  final String message;
  final int resultCount;

  const BookSourceTestResult({
    required this.success,
    required this.message,
    this.resultCount = 0,
  });
}

/// 测试书源是否可用（用搜索 URL 尝试抓取）
class TestBookSource {
  final SearchRepository _searchRepo;

  TestBookSource({SearchRepository? searchRepo})
      : _searchRepo = searchRepo ?? SearchRepositoryImpl();

  /// 用关键词测试书源搜索是否正常
  Future<BookSourceTestResult> testSearch(BookSource source, String keyword) async {
    if (source.searchUrl == null || source.bookListRule == null) {
      return const BookSourceTestResult(
        success: false,
        message: '书源缺少搜索 URL 或书籍列表规则',
      );
    }
    try {
      final results = await _searchRepo.searchWithSource(keyword, source);
      if (results.isEmpty) {
        return const BookSourceTestResult(
          success: false,
          message: '搜索成功但未解析到结果（规则可能不匹配）',
        );
      }
      return BookSourceTestResult(
        success: true,
        message: '搜索成功，找到 ${results.length} 个结果',
        resultCount: results.length,
      );
    } catch (e) {
      return BookSourceTestResult(
        success: false,
        message: '请求失败: $e',
      );
    }
  }

  /// 将当前表单构建为 BookSource 测试
  BookSource buildTestSource({
    required String name,
    String? url,
    String? group,
    required Map<String, dynamic> rules,
  }) {
    return BookSource(
      id: 'test_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      bookSourceUrl: url,
      bookSourceGroup: group,
      enabled: true,
      rules: rules,
    );
  }
}
