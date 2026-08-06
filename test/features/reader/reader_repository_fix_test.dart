import 'dart:io';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 可配置的动态 mock：按 URL 返回不同 HTML，并记录调用
class _DynamicClient implements DioClient {
  _DynamicClient(this.responder);

  final String Function(String url) responder;

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    return responder(url);
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

  @override
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

  @override
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return '';
  }

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    return '';
  }
}

class _SourceRepo implements BookSourceRepository {
  final BookSource source;
  _SourceRepo(this.source);


  @override
  Future<List<BookSource>> getAll() async => [source];
  @override
  Future<BookSource?> getById(String id) async => source;
  @override
  Future<void> save(BookSource source) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> importFromJson(String jsonString) async {}
  @override
  Future<void> importFromUrl(String url) async {}
  @override
  Future<List<BookSource>> getEnabled() async => [source];
}

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_reader_fix').path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(ChapterModelAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ReadingProgressModelAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('reader_repository 修复回归', () {
    test('#1/#3 兜底正文提取命中真实正文且跳过 script', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          // 失配正文规则，触发 _extractMainText 兜底
          'chapterContent': '.nonexistent',
        },
      );
      final scriptText = 'a' * 1500; // 比 body 内真实正文长
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        // 正文页：真实正文较短，script 文本很长
        return '<body>'
            '<div><p>这是正文片段这是正文片段这是正文片段这是正文片段这是正文片段。</p></div>'
            '<script>$scriptText</script>'
            '</body>';
      });
      final repo = ReaderRepositoryImpl(
          client: client, sourceRepo: _SourceRepo(source));

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content.contains('这是正文片段'), isTrue);
      expect(chapter.content.contains(scriptText), isFalse,
          reason: 'script 内文本不应被当作正文');
    });

    test('#2 目录加载失败抛 ChapterLoadException 而非返空目录', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
        },
      );
      final client = _DynamicClient((_) {
        throw DioException(
          requestOptions: RequestOptions(path: 'https://example.com/book/1'),
          type: DioExceptionType.connectionTimeout,
        );
      });
      final repo = ReaderRepositoryImpl(
          client: client, sourceRepo: _SourceRepo(source));

      await expectLater(
        repo.getCatalog(
          bookId: 'book1',
          sourceId: 'src1',
          detailUrl: 'https://example.com/book/1',
        ),
        throwsA(isA<ChapterLoadException>()
            .having((e) => e.message, 'message', '目录加载失败')),
      );
    });

    test('#2 目录加载失败不阻断正文：getChapter 降级到 contentUrl 兜底',
        () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          // contentUrl 模板让正文页走独立 URL（与目录页 /book/ 区分）：
          // 目录失败后 chapterUrl 为空 → {{id}} 替换为空 → /content/
          'contentUrl': 'https://example.com/content/{{id}}',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          // 目录页：抛超时
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.connectionTimeout,
          );
        }
        // 正文页（/content/）：返回正文
        return '<div><p>兜底正文内容兜底正文内容兜底正文内容兜底正文内容兜底正文内容'
            '兜底正文内容兜底正文内容兜底正文内容兜底正文内容兜底正文内容'
            '兜底正文内容兜底正文内容兜底正文内容兜底正文内容兜底正文内容'
            '兜底正文内容兜底正文内容兜底正文内容兜底正文内容兜底正文内容</p></div>';
      });
      final repo = ReaderRepositoryImpl(
          client: client, sourceRepo: _SourceRepo(source));

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, isNotEmpty);
      expect(chapter.content.contains('兜底正文内容'), isTrue);
    });

    test('#4 正文容器内嵌长 script 时 _extractMainText 排除脚本文本',
        () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          // 失配正文规则，触发 _extractMainText 兜底
          'chapterContent': '.nonexistent',
        },
      );
      // 正文容器文本 >= 200 字（满足候选阈值），且容器内嵌更长 script。
      // 修复前 Element.text 会包含嵌套脚本文本 → 脚本被误当正文；
      // 修复后 _visibleText 跳过 script 子树 → 只选中真实正文。
      // 注意正文必须 >= 200 字：否则 best 恒空，兜底落到整页净化，
      // 测试就不在测 _extractMainText 路径（'真实正文内容'=6 字，×40=240）。
      final bodyText = '真实正文内容' * 40; // 240 字，超过 200 阈值
      final scriptText = 'a' * 1500;
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        // 正文容器 <div> 内嵌 <script>：Element.text 会包含脚本文本
        return '<body><div><p>$bodyText</p>'
            '<script>$scriptText</script>'
            '</div></body>';
      });
      final repo = ReaderRepositoryImpl(
          client: client, sourceRepo: _SourceRepo(source));

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      );
      // 触发的是 _extractMainText（非整页净化），正文应为纯文本且不含脚本
      expect(chapter.content.contains('真实正文内容'), isTrue);
      expect(chapter.content.contains(scriptText), isFalse,
          reason: '正文容器内嵌的脚本文本不应被当作正文');
      // 兜底提取返回的是纯文本，不应包含 HTML 标签
      expect(chapter.content.contains('<script>'), isFalse);
    });

    test('#1 "无法定位章节" 错误不被兜底文案覆盖', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          // 无 contentUrl，无 chapterUrl（目录空），无 detailUrl → 无法定位
        },
      );
      // 目录正常返回但无章节 → chapterUrl 空；无 detailUrl → 抛"无法定位章节"
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul></ul>';
        }
        return '';
      });
      final repo = ReaderRepositoryImpl(
          client: client, sourceRepo: _SourceRepo(source));

      await expectLater(
        repo.getChapter(
          bookId: 'book1',
          chapterIndex: 0,
          sourceId: 'src1',
          // 无 detailUrl，触发"无法定位章节"
        ),
        throwsA(isA<ChapterLoadException>()
            .having((e) => e.message, 'message', '无法定位章节')),
      );
    });
  });
}