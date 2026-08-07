import 'dart:io';
import 'package:dio/dio.dart';
import 'package:easy_read/core/data/cookie_jar_service.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/core/purification/purify_pipeline.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/search/data/engines/js_rule_executor.dart';
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
    String? charset,
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
    String? charset,
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

class _FakeCookieJar extends CookieJarService {
  String? stored;

  @override
  Future<String?> get(String sourceId) async => stored;

  @override
  Future<void> set(String sourceId, String cookie) async {
    stored = cookie;
  }

  @override
  Future<void> remove(String sourceId) async {
    stored = null;
  }
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
    test('完整 JS 正文规则可展开 @get 变量', () async {
      const source = BookSource(
        id: 'js-content-var',
        name: 'JS正文变量源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterContent': "@js:java.getString('@get:{sel}')",
        },
      );
      final client = _DynamicClient(
        (_) => '<div><h1>正文变量</h1></div>',
      );
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final chapter = await repo.getChapter(
        bookId: 'book-var',
        chapterIndex: 0,
        sourceId: 'js-content-var',
        detailUrl: 'https://example.com/book/1',
        variables: const {'sel': 'h1'},
      );
      expect(chapter.content, contains('正文变量'));
    });

    test('loginCheckJs 替换正文并回写 CookieJar', () async {
      const source = BookSource(
        id: 'login-reader',
        name: '登录阅读源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterContent': '#content@text',
          'loginCheckJs':
              "@js:cookie.setCookie(source.getKey(), 'session=xyz'); "
              "'<div id=\"content\"><p>登录正文</p></div>'",
        },
      );
      final client = _DynamicClient(
        (_) => '<div>旧正文</div>',
      );
      final cookieJar = _FakeCookieJar();
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
        cookieJar: cookieJar,
      );
      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'login-reader',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('登录正文'));
      expect(cookieJar.stored, 'session=xyz');
    });

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

    test('本地导入章节 v3 key 可直接读取', () async {
      final box = await Hive.openBox<ChapterModel>('chapters');
      await box.put(
        'v3_book1_local_0',
        ChapterModel(
          id: 'v3_book1_local_0',
          bookId: 'book1',
          title: '第一章',
          content: '本地正文',
          index: 0,
          sourceId: 'local',
          cachedAt: DateTime.now(),
        ),
      );
      final repo = ReaderRepositoryImpl(
        client: _DynamicClient((_) => ''),
        sourceRepo: _SourceRepo(
          const BookSource(id: 'unused', name: 'unused'),
        ),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'local',
      );
      expect(chapter.content, '本地正文');
    });

    test('旧版本地缓存 key 可兼容读取', () async {
      final box = await Hive.openBox<ChapterModel>('chapters');
      await box.put(
        'book1_local_0',
        ChapterModel(
          id: 'book1_local_0',
          bookId: 'book1',
          title: '第一章',
          content: '旧本地正文',
          index: 0,
          sourceId: 'local',
          cachedAt: DateTime.now(),
        ),
      );
      final repo = ReaderRepositoryImpl(
        client: _DynamicClient((_) => ''),
        sourceRepo: _SourceRepo(
          const BookSource(id: 'unused', name: 'unused'),
        ),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'local',
      );
      expect(chapter.content, '旧本地正文');
    });

    test('相对详情 URL 基于书源地址 resolve', () async {
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
      final client = _DynamicClient((url) {
        expect(url, 'https://example.com/book/1');
        return '<ul><li><a href="/ch/1">第一章</a></li></ul>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'src1',
        detailUrl: '/book/1',
      );
      expect(catalog.chapters.single.url, '/ch/1');
    });

    test('成功规则提取仍经过净化管线', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterContent': 'div.content@text',
        },
      );
      final client = _DynamicClient(
        (_) => '<div class="content">正文内容</div>',
      );
      final pipeline = PurifyPipeline(
        regexPurifier: const RegexPurifier(
          rules: [PurifyRule(pattern: '正文', replacement: '净化')],
        ),
      );
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
        pipeline: pipeline,
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('净化内容'));
    });

    test('智能正文兜底保留段落结构', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterContent': '.missing',
        },
      );
      final client = _DynamicClient(
        (_) => '<body><div><p>第一段</p><p>第二段</p></div></body>',
      );
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('<p>第一段</p>'));
      expect(chapter.content, contains('<p>第二段</p>'));
    });

    test('完整 JS 正文规则可执行', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterContent': r'<js>r = result.match(/<p>(.*?)<\/p>/); r[1]</js>',
        },
      );
      final client = _DynamicClient((_) => '<p>JS正文</p>');
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('JS正文'));
    });

    test('完整 JS chapterList 返回 JSON 数组时解析目录', () async {
      final raw = await JsRuleExecutor.execute(
        '',
        r"<js>JSON.stringify([{n:'第一章',u:'/ch/1'}])</js>",
      );
      expect(raw, isNotNull, reason: 'JS 目录规则应返回 JSON');
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': r"<js>JSON.stringify([{n:'第一章',u:'/ch/1'}])</js>",
          'chapterName': r'$.n',
          'chapterUrl': r'$.u',
        },
      );
      final repo = ReaderRepositoryImpl(
        client: _DynamicClient((_) => ''),
        sourceRepo: _SourceRepo(source),
      );

      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      );
      expect(catalog.chapters.single.title, '第一章');
      expect(catalog.chapters.single.url, '/ch/1');
    });

    test('ruleBookInfo 先解析详情再按 tocUrl 拉取目录', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'ruleBookInfo': {
            'init': r'$.data',
            'tocUrl': r'/catalog?book_id={{$.book_id}}',
          },
          'ruleToc': {
            'chapterList': r'$.data',
            'chapterName': r'$.title',
            'chapterUrl': r'/content?item_id={{$.item_id}}',
          },
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '{"data":{"book_id":"1"}}';
        }
        if (url.contains('/catalog')) {
          return '{"data":[{"title":"第一章","item_id":"a"}]}';
        }
        return '';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'src1',
        detailUrl: '/book/1',
      );
      expect(catalog.chapters.single.title, '第一章');
      expect(catalog.chapters.single.url, '/content?item_id=a');
    });

    test('getBookDetail 返回详情字段', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'ruleBookInfo': {
            'init': r'$.data',
            'name': r'$.name',
            'author': r'$.author',
            'intro': r'$.intro',
            'coverUrl': r'$.cover_url',
            'lastChapter': r'$.last_chapter',
            'tocUrl': r'/catalog?book_id={{$.book_id}}',
          },
          'ruleToc': {
            'chapterList': r'$.data',
            'chapterName': r'$.title',
            'chapterUrl': r'/content?item_id={{$.item_id}}',
          },
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '{"data":{"book_id":"1","name":"书A","author":"作者A",'
              '"intro":"简介内容","cover_url":"/cover.jpg","last_chapter":"第100章"}}';
        }
        return '{"data":[{"title":"第一章","item_id":"a"}]}';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final detail = await repo.getBookDetail(
        bookId: 'book1',
        sourceId: 'src1',
        detailUrl: '/book/1',
      );
      expect(detail.name, '书A');
      expect(detail.author, '作者A');
      expect(detail.intro, '简介内容');
      expect(detail.coverUrl, 'https://example.com/cover.jpg');
      expect(detail.lastChapter, '第100章');
    });

    test('JSONPath 正文规则直接提取 JSON 内容', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'ruleToc': {
            'chapterList': r'$.data',
            'chapterName': r'$.title',
            'chapterUrl': r'/content?item_id={{$.item_id}}',
          },
          'ruleContent': {
            'content': r'$.content',
          },
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '{"data":[{"title":"第一章","item_id":"a"}]}';
        }
        return '{"content":"JSON正文"}';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: '/book/1',
      );
      expect(chapter.content, contains('JSON正文'));
    });

    test('目录分页 nextTocUrl 自动拼接章节', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'ruleToc': {
            'chapterList': r'$.data',
            'chapterName': r'$.title',
            'chapterUrl': r'/content?item_id={{$.item_id}}',
            'nextTocUrl': r'$.next_url',
          },
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/toc/2')) {
          return '{"data":[{"title":"第二章","item_id":"b"}]}';
        }
        return '{"data":[{"title":"第一章","item_id":"a"}],"next_url":"/toc/2"}';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'src1',
        detailUrl: '/book/1',
      );
      expect(catalog.chapters.map((c) => c.title), ['第一章', '第二章']);
    });

    test('正文分页 nextContentUrl 自动拼接内容', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'ruleContent': {
            'content': r'$.content',
            'nextContentUrl': r'$.next_url',
          },
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/ch/2')) {
          return '{"content":"第二页"}';
        }
        return '{"content":"第一页","next_url":"/ch/2"}';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: '/book/1',
      );
      expect(chapter.content, contains('第一页'));
      expect(chapter.content, contains('第二页'));
    });

    test('正文开头重复章节标题自动去除', () async {
      const source = BookSource(
        id: 'src1',
        name: '测试源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'chapterContent': 'div.content@text',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="/ch/1">第一章 开始</a></li></ul>';
        }
        return '<div class="content">第一章 开始正文内容</div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: '/book/1',
      );
      expect(chapter.content, isNot(startsWith('第一章 开始')));
      expect(chapter.content, contains('正文内容'));
    });

    test('目录 @put 变量用于正文 URL @get', () async {
      const source = BookSource(
        id: 'srcVar',
        name: '变量源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': r'a@text@put:{cid:span.cid@text}',
          'chapterUrl': 'a@href',
          'contentUrl': 'https://example.com/content/@get:{cid}/{{id}}',
          'chapterContent': '#content',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="/ch/1">第一章</a>'
              '<span class="cid">99</span></li></ul>';
        }
        if (url.contains('/content/99/')) {
          return '<div id="content">变量正文</div>';
        }
        return '<div id="content">错误 URL</div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );

      final catalog = await repo.getCatalog(
        bookId: 'bookVar',
        sourceId: 'srcVar',
        detailUrl: 'https://example.com/book/1',
      );
      expect(catalog.chapters.single.variables, {'cid': '99'});
      final chapter = await repo.getChapter(
        bookId: 'bookVar',
        chapterIndex: 0,
        sourceId: 'srcVar',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('变量正文'));
    });
  });
}
