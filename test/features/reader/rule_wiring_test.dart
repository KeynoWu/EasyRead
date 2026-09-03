import 'dart:io';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 按 URL 返回不同 HTML 的 mock 客户端（同既有 reader 测试惯例）
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

    String? concurrentRate,
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

    String? concurrentRate,
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

    String? concurrentRate,
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

    String? concurrentRate,
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

    String? concurrentRate,
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

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_rule_wiring').path);
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

  group('ruleContent.title 正文标题规则', () {
    test('正文 title 规则提取非空时覆盖目录标题', () async {
      const source = BookSource(
        id: 'title-src',
        name: '标题源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'chapterContent': '.content@text',
          'ruleContent': {'title': 'h1@text'},
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">目录标题</a></li></ul>';
        }
        return '<div><h1>正文标题</h1>'
            '<div class="content"><p>正文内容。</p></div></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'title-src',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.title, '正文标题');
      expect(chapter.content, contains('正文内容。'));
    });

    test('正文 title 规则提取为空时保留目录标题', () async {
      const source = BookSource(
        id: 'title-empty',
        name: '标题源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'chapterContent': '.content@text',
          'ruleContent': {'title': '.no-such-h1@text'},
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">目录标题</a></li></ul>';
        }
        return '<div><div class="content"><p>正文内容。</p></div></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'title-empty',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.title, '目录标题');
    });
  });

  group('ruleContent.subContent 子内容规则', () {
    test('每个匹配子元素按顺序追加到主正文后', () async {
      const source = BookSource(
        id: 'sub-src',
        name: '子内容源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'chapterContent': '.main@text',
          'ruleContent': {'subContent': '.note'},
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        return '<div class="main"><p>主正文。</p></div>'
            '<div class="note">注释一</div>'
            '<div class="note">注释二</div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'sub-src',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('主正文。'));
      // 子元素以 HTML 片段追加，且保持页面顺序
      expect(chapter.content, contains('<div class="note">注释一</div>'));
      expect(chapter.content, contains('<div class="note">注释二</div>'));
      expect(chapter.content.indexOf('主正文。'),
          lessThan(chapter.content.indexOf('注释一')));
      expect(chapter.content.indexOf('注释一'),
          lessThan(chapter.content.indexOf('注释二')));
    });

    test('无 subContent 规则时行为不变', () async {
      const source = BookSource(
        id: 'no-sub',
        name: '无子内容源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'chapterContent': '.main@text',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        return '<div class="main"><p>主正文。</p></div>'
            '<div class="note">注释一</div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'no-sub',
        detailUrl: 'https://example.com/book/1',
      );
      expect(chapter.content, contains('主正文。'));
      expect(chapter.content, isNot(contains('注释一')));
    });
  });

  group('ruleContent.replaceRegex 正文替换', () {
    Future<String> contentWithReplaceRegex(String replaceRegex) async {
      final source = BookSource(
        id: 'rr-$replaceRegex',
        name: '替换源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'chapterContent': '.content@text',
          'ruleContent': {'replaceRegex': replaceRegex},
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        return '<div class="content"><p>正文内容。</p></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final chapter = await repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: source.id,
        detailUrl: 'https://example.com/book/1',
      );
      return chapter.content;
    }

    test('JSON 数组格式 ["pattern","replacement"] 全替换', () async {
      final content = await contentWithReplaceRegex(r'["正文", "正X"]');
      expect(content, contains('正X内容。'));
      expect(content, isNot(contains('正文内容。')));
    });

    test('JSON 数组正则匹配全部出现', () async {
      final content = await contentWithReplaceRegex(r'["内容", "X"]');
      expect(content, contains('正文X。'));
    });

    test('|| 分隔格式 pattern||replacement 替换', () async {
      final content = await contentWithReplaceRegex('正文||正Y');
      expect(content, contains('正Y内容。'));
      expect(content, isNot(contains('正文内容。')));
    });

    test('非法 JSON 且无 || 分隔时跳过不报错', () async {
      final content = await contentWithReplaceRegex('[');
      expect(content, contains('正文内容。'));
    });

    test('非法正则时跳过不报错', () async {
      final content = await contentWithReplaceRegex(r'["a(", "X"]');
      expect(content, contains('正文内容。'));
    });
  });

  group('ruleToc.formatJs 目录项格式化', () {
    Future<ChapterCatalog> catalogWithFormatJs(String formatJs) async {
      final source = BookSource(
        id: 'fmt-$formatJs',
        name: '格式化源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'ruleToc': {'formatJs': formatJs},
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">目录标题</a></li></ul>';
        }
        return '<div><p>正文。</p></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      return repo.getCatalog(
        bookId: 'book1',
        sourceId: source.id,
        detailUrl: 'https://example.com/book/1',
      );
    }

    test('脚本内 item 可修改 title/url 并返回', () async {
      final catalog = await catalogWithFormatJs(
        "@js:item.title = item.title.replace('目录', '章节'); "
        "item.url = 'https://example.com/ch/9'; item;",
      );
      expect(catalog.chapters, hasLength(1));
      expect(catalog.chapters.first.title, '章节标题');
      expect(catalog.chapters.first.url, 'https://example.com/ch/9');
    });

    test('IIFE + return item 风格（闭包修改外层 item）同样生效', () async {
      final catalog = await catalogWithFormatJs(
        "@js:(function () { item.title = item.title + '·改'; return item; })()",
      );
      expect(catalog.chapters.first.title, '目录标题·改');
    });

    test('执行失败时保留原目录项', () async {
      final catalog = await catalogWithFormatJs("@js:throw new Error('boom')");
      expect(catalog.chapters.first.title, '目录标题');
      expect(catalog.chapters.first.url, 'https://example.com/ch/1');
    });

    test('非 JS 规则按原 item 兜底', () async {
      final catalog = await catalogWithFormatJs('tag.span');
      expect(catalog.chapters.first.title, '目录标题');
      expect(catalog.chapters.first.url, 'https://example.com/ch/1');
    });
  });

  group('ruleToc.isVolume 卷节点标记', () {
    test('CSS 规则对目录项求值标记卷头', () async {
      const source = BookSource(
        id: 'vol-css',
        name: '卷标记源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'ruleToc': {'isVolume': 'tag.span'},
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul>'
              '<li class="volume"><span>第一卷</span>'
              '<a href="https://example.com/v/1">第一卷 楔子</a></li>'
              '<li><a href="https://example.com/ch/1">第一章</a></li>'
              '</ul>';
        }
        return '<div><p>正文。</p></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'vol-css',
        detailUrl: 'https://example.com/book/1',
      );
      expect(catalog.chapters, hasLength(2));
      expect(catalog.chapters[0].isVolume, isTrue);
      expect(catalog.chapters[1].isVolume, isFalse);
    });

    test('JS 规则按 item 求值标记卷头', () async {
      const source = BookSource(
        id: 'vol-js',
        name: '卷标记源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
          'ruleToc': {'isVolume': "@js:item.title.includes('卷')"},
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul>'
              '<li><a href="https://example.com/v/1">第一卷</a></li>'
              '<li><a href="https://example.com/ch/1">第一章</a></li>'
              '</ul>';
        }
        return '<div><p>正文。</p></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'vol-js',
        detailUrl: 'https://example.com/book/1',
      );
      expect(catalog.chapters, hasLength(2));
      expect(catalog.chapters[0].isVolume, isTrue);
      expect(catalog.chapters[1].isVolume, isFalse);
    });

    test('无 isVolume 规则时标记为 null（回归安全）', () async {
      const source = BookSource(
        id: 'vol-none',
        name: '无卷规则源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        return '<div><p>正文。</p></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'vol-none',
        detailUrl: 'https://example.com/book/1',
      );
      expect(catalog.chapters.first.isVolume, isNull);
    });
  });

  group('bookUrlPattern 匹配与容错', () {
    test('matchesBookUrlPattern 匹配/不匹配/空与非法容错', () {
      expect(
        ReaderRepositoryImpl.matchesBookUrlPattern(
          r'^https://example\.com/',
          'https://example.com/book/1',
        ),
        isTrue,
      );
      expect(
        ReaderRepositoryImpl.matchesBookUrlPattern(
          r'^https://other\.com/',
          'https://example.com/book/1',
        ),
        isFalse,
      );
      expect(
        ReaderRepositoryImpl.matchesBookUrlPattern(
          null,
          'https://example.com/book/1',
        ),
        isTrue,
      );
      expect(
        ReaderRepositoryImpl.matchesBookUrlPattern(
          '',
          'https://example.com/book/1',
        ),
        isTrue,
      );
      // 非法正则：放行不阻塞
      expect(
        ReaderRepositoryImpl.matchesBookUrlPattern(
          'a(',
          'https://example.com/book/1',
        ),
        isTrue,
      );
    });

    test('bookUrlPattern 不匹配时仅告警、不阻塞目录拉取', () async {
      const source = BookSource(
        id: 'pattern-src',
        name: '匹配源',
        bookSourceUrl: 'https://example.com',
        rules: {
          'bookUrlPattern': r'^https://other\.com/',
          'chapterList': 'ul > li',
          'chapterName': 'a',
          'chapterUrl': 'a@href',
        },
      );
      final client = _DynamicClient((url) {
        if (url.contains('/book/')) {
          return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
        }
        return '<div><p>正文。</p></div>';
      });
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(source),
      );
      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'pattern-src',
        detailUrl: 'https://example.com/book/1',
      );
      expect(catalog.chapters, hasLength(1));
      expect(catalog.chapters.first.title, '第一章');
    });
  });
}
