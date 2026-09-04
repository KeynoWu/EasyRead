import 'package:dio/dio.dart';
import '../../../reader/domain/entities/chapter_catalog.dart';
import '../../../reader/domain/repositories/reader_repository.dart';
import '../../../reader/data/repositories/reader_repository_impl.dart' show ChapterLoadException;
import '../../../search/data/repositories/search_repository_impl.dart';
import '../../../search/domain/entities/search_result.dart';
import '../../../search/domain/repositories/search_repository.dart';
import '../entities/book_source.dart';

/// 书源校验结果
class BookSourceTestResult {
  final bool success;
  final String message;
  final int resultCount;
  final List<SearchResult> samples;

  const BookSourceTestResult({
    required this.success,
    required this.message,
    this.resultCount = 0,
    this.samples = const [],
  });
}

/// 测试书源是否可用（用搜索 URL 尝试抓取；支持全链路检测）
class TestBookSource {
  final SearchRepository _searchRepo;

  /// 目录/正文检测仓库（null 时仅做搜索检测）
  final ReaderRepository? readerRepo;

  /// 全链路检测时的虚拟 bookId（检测结果不与真实书架冲突）
  static const String _testBookId = '__source_check__';

  TestBookSource({SearchRepository? searchRepo, this.readerRepo})
      : _searchRepo = searchRepo ?? SearchRepositoryImpl();

  /// 用关键词测试书源搜索是否正常。
  /// [keyword] 为批测统一关键词；源自带 `checkKeyWord` 时优先（Legado
  /// BookSource.getCheckKeyword 语义：源级检测词覆盖默认词）。
  Future<BookSourceTestResult> testSearch(
    BookSource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    if (source.searchUrl == null || source.bookListRule == null) {
      return const BookSourceTestResult(
        success: false,
        message: '书源缺少搜索 URL 或书籍列表规则',
      );
    }
    final effectiveKeyword = (source.checkKeyWord?.trim().isNotEmpty ?? false)
        ? source.checkKeyWord!.trim()
        : keyword;
    try {
      final results = await _searchRepo.searchWithSource(
        effectiveKeyword,
        source,
        cancelToken: cancelToken,
        throwOnError: true,
      );
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
        samples: results.take(3).toList(),
      );
    } on DioException catch (e) {
      return BookSourceTestResult(
        success: false,
        message: '请求失败: ${_friendlyError(e)}',
      );
    } catch (e) {
      return const BookSourceTestResult(
        success: false,
        message: '规则错误或解析失败',
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

  /// 将 Dio 异常转为不含服务器细节的友好分类文案，便于检测结果分类展示
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

  /// 全链路检测（§三-11，Legado CheckSourceService doCheckSource +
  /// checkBook）：搜索 → 目录（前 2 章）→ 首章正文，逐级打失效分组标签。
  /// 返回分组列表（空 = 全链路可用）；[samples] 透传搜索样例供 UI 预览。
  Future<(List<String>, List<SearchResult>)> testFullChain(
    BookSource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    final groups = <String>[];
    // 源级检测词优先（Legado getCheckKeyword）；在此解析使子类覆写
    // testSearch 时同样生效
    final effectiveKeyword = (source.checkKeyWord?.trim().isNotEmpty ?? false)
        ? source.checkKeyWord!.trim()
        : keyword;
    // 1. 搜索
    final search =
        await testSearch(source, effectiveKeyword, cancelToken: cancelToken);
    if (!search.success) {
      // 搜索失败即全链路失败，不继续目录/正文（Legado 同样短路）
      return (['搜索失效'], const <SearchResult>[]);
    }
    final samples = search.samples;
    if (samples.isEmpty) return (['搜索失效'], const <SearchResult>[]);
    final readerRepo = this.readerRepo;
    if (readerRepo == null) return (groups, samples);

    final first = samples.first;
    final detailUrl = first.detailUrl;
    if (detailUrl == null || detailUrl.isEmpty) {
      return (['详情链接缺失'], samples);
    }
    // 2. 目录（前 2 章可定位即视为有效，Legado toc.take(2)）
    if (source.chapterListRule == null) {
      groups.add('目录规则为空');
      return (groups, samples);
    }
    final List<ChapterItem> toc;
    try {
      final catalog = await readerRepo.getCatalog(
        bookId: _testBookId,
        sourceId: source.id,
        detailUrl: detailUrl,
        variables: first.variables,
      );
      toc = catalog.chapters;
    } on ChapterLoadException {
      return (['目录失效'], samples);
    } catch (_) {
      return (['目录失效'], samples);
    }
    if (toc.isEmpty) return (['目录失效'], samples);

    // 3. 首章正文（非空即通过；Legado getContentAwait 失败打正文失效）
    try {
      final chapter = await readerRepo.getChapter(
        bookId: _testBookId,
        chapterIndex: 0,
        sourceId: source.id,
        detailUrl: detailUrl,
        variables: first.variables,
      );
      if (chapter.content.trim().isEmpty) {
        groups.add('正文失效');
      }
    } on ChapterLoadException catch (e) {
      if (e.message.contains('为空') || e.message.contains('空内容')) {
        groups.add('正文失效');
      } else {
        groups.add('正文失效');
      }
    } catch (_) {
      groups.add('正文失效');
    }
    return (groups, samples);
  }
}
