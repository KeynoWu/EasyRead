import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/data/services/book_cache_service.dart';
import 'package:easy_read/features/reader/data/services/book_exporter.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 按 URL 返回不同 HTML，并统计正文页（/ch/）请求次数
class _DynamicClient implements DioClient {
  _DynamicClient(this.responder);

  final String Function(String url) responder;
  int contentRequests = 0;

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
    if (url.contains('/ch/')) contentRequests++;
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

/// 三章测试书：目录页 /book/1，正文页 /ch/0..2
const _source = BookSource(
  id: 'cache-src',
  name: '缓存导出源',
  bookSourceUrl: 'https://example.com',
  rules: {
    'chapterList': 'ul > li',
    'chapterName': 'a',
    'chapterUrl': 'a@href',
    'chapterContent': '#content@text',
  },
);

_DynamicClient _buildClient() {
  const numerals = ['一', '二', '三'];
  return _DynamicClient((url) {
    if (url.contains('/book/')) {
      return '<ul>'
          '<li><a href="https://example.com/ch/0">第一章</a></li>'
          '<li><a href="https://example.com/ch/1">第二章</a></li>'
          '<li><a href="https://example.com/ch/2">第三章</a></li>'
          '</ul>';
    }
    final index = int.parse(RegExp(r'/ch/(\d+)').firstMatch(url)!.group(1)!);
    final name = '第${numerals[index]}章';
    final body = '这是$name的正文内容这是$name的正文内容';
    return '<div id="content"><p>$body</p></div>';
  });
}

/// 缓存全书（三章）并返回 [BookCacheService] 与目录
Future<(BookCacheService, _DynamicClient, ChapterCatalog)> _cacheAllBook() async {
  final client = _buildClient();
  final repo = ReaderRepositoryImpl(
    client: client,
    sourceRepo: _SourceRepo(_source),
  );
  final service = BookCacheService(repository: repo);
  final catalog = await repo.getCatalog(
    bookId: 'book1',
    sourceId: 'cache-src',
    detailUrl: 'https://example.com/book/1',
  );
  final result = await service.cacheBook(
    bookId: 'book1',
    sourceId: 'cache-src',
    detailUrl: 'https://example.com/book/1',
    chapters: catalog.chapters,
  );
  expect(result.cached, 3);
  return (service, client, catalog);
}

/// 假保存回调：写入临时目录并返回路径
BookSaveFile _fakeSaveFile(Directory dir) {
  return (Uint8List bytes, String fileName) async {
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    return file.path;
  };
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('hive_book_export');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(ChapterModelAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ReadingProgressModelAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('BookCacheService 整本缓存', () {
    test('断点续传：已缓存章节跳过，不重复拉取正文', () async {
      final client = _buildClient();
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(_source),
      );
      final service = BookCacheService(repository: repo);
      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
      );

      final first = await service.cacheBook(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
        chapters: catalog.chapters,
      );
      expect(first.cached, 3);
      expect(first.hit, 0);
      expect(first.failed, 0);
      expect(client.contentRequests, 3);

      final second = await service.cacheBook(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
        chapters: catalog.chapters,
      );
      expect(second.cached, 0);
      expect(second.hit, 3);
      expect(client.contentRequests, 3,
          reason: '断点续传不应重新拉取已缓存章节');
      expect(await service.countCached('book1'), 3);
    });

    test('可取消：取消后返回 cancelled，已缓存部分保留', () async {
      final client = _buildClient();
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(_source),
      );
      final service = BookCacheService(repository: repo);
      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
      );
      final cancelToken = CancelToken();
      var progressCalls = 0;
      final result = await service.cacheBook(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
        chapters: catalog.chapters,
        cancelToken: cancelToken,
        onProgress: (done, total, title) {
          progressCalls++;
          if (progressCalls == 1) cancelToken.cancel();
        },
      );
      expect(result.cancelled, isTrue);
      expect(result.cached, 1, reason: '第一章缓存完成后取消');
      // 已缓存部分可读取
      expect(await BookCacheBox.readChapter('book1', 0), contains('第一章的正文'));
      // 元数据已写入：取消后仍可导出已缓存部分
      final meta = await service.meta('book1');
      expect(meta?['sourceId'], 'cache-src');
    });

    test('未传 chapters 时按目录自动拉取并缓存', () async {
      final client = _buildClient();
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(_source),
      );
      final service = BookCacheService(repository: repo);
      final result = await service.cacheBook(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
      );
      expect(result.cached, 3);
      expect(await service.countCached('book1'), 3);
    });
  });

  group('BookExporter TXT 导出', () {
    test('结构：书名/作者头 + 每章标题行与正文、章节分隔', () async {
      await _cacheAllBook();
      final exporter = BookExporter(saveFile: _fakeSaveFile(tempDir));
      final result = await exporter.exportTxt(
        bookId: 'book1',
        sourceId: 'cache-src',
        bookName: '测试之书',
        author: '作者甲',
        chapters: (await _catalog()).chapters,
      );
      expect(result.path, isNotNull);
      expect(result.exported, 3);
      expect(result.skipped, 0);
      final text = await File(result.path!).readAsString();
      // 标题头
      expect(text, startsWith('测试之书\n作者甲\n'));
      // 章节标题行 + 章节分隔（标题行后紧跟正文，章节间空行）
      expect(text, contains('第一章\n这是第一章的正文内容'));
      expect(text, contains('第二章\n这是第二章的正文内容'));
      expect(text, contains('第三章\n这是第三章的正文内容'));
      // 无 HTML 标签残留
      expect(text, isNot(contains('<div')));
    });

    test('未缓存章节跳过并计数', () async {
      final client = _buildClient();
      final repo = ReaderRepositoryImpl(
        client: client,
        sourceRepo: _SourceRepo(_source),
      );
      final service = BookCacheService(repository: repo);
      final catalog = await repo.getCatalog(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
      );
      // 只缓存第 1、3 章，第 2 章留空
      await service.cacheBook(
        bookId: 'book1',
        sourceId: 'cache-src',
        detailUrl: 'https://example.com/book/1',
        chapters: [catalog.chapters[0], catalog.chapters[2]],
      );
      final exporter = BookExporter(saveFile: _fakeSaveFile(tempDir));
      final result = await exporter.exportTxt(
        bookId: 'book1',
        sourceId: 'cache-src',
        bookName: '测试之书',
        chapters: catalog.chapters,
      );
      expect(result.exported, 2);
      expect(result.skipped, 1);
      final text = await File(result.path!).readAsString();
      expect(text, contains('这是第一章的正文内容'));
      expect(text, contains('这是第三章的正文内容'));
      expect(text, isNot(contains('这是第二章的正文内容')));
    });

    test('meta sourceId 不一致抛 ExportSourceMismatchException', () async {
      await _cacheAllBook();
      final exporter = BookExporter(saveFile: _fakeSaveFile(tempDir));
      await expectLater(
        exporter.exportTxt(
          bookId: 'book1',
          sourceId: 'other-src',
          bookName: '测试之书',
          chapters: (await _catalog()).chapters,
        ),
        throwsA(isA<ExportSourceMismatchException>()),
      );
    });
  });

  group('BookExporter EPUB 导出', () {
    test('zip 结构：mimetype 第一项且 STORED、container.xml、spine 顺序、章节内容',
        () async {
      await _cacheAllBook();
      final exporter = BookExporter(saveFile: _fakeSaveFile(tempDir));
      final result = await exporter.exportEpub(
        bookId: 'book1',
        sourceId: 'cache-src',
        bookName: '测试之书',
        author: '作者甲',
        chapters: (await _catalog()).chapters,
      );
      expect(result.path, isNotNull);
      expect(result.exported, 3);
      expect(result.skipped, 0);

      final bytes = await File(result.path!).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      // mimetype 第一项且未压缩（STORED）
      expect(archive.files.first.name, 'mimetype');
      expect(utf8.decode(archive.files.first.content), 'application/epub+zip');
      expect(archive.files.first.compression, CompressionType.none);
      // container.xml 指向 OEBPS/content.opf
      final container = utf8.decode(
          archive.findFile('META-INF/container.xml')!.content);
      expect(container, contains('OEBPS/content.opf'));
      // opf：标题/语言/creator 与 spine 顺序
      final opf = utf8.decode(archive.findFile('OEBPS/content.opf')!.content);
      expect(opf, contains('<dc:title>测试之书</dc:title>'));
      expect(opf, contains('<dc:creator opf:role="aut">作者甲</dc:creator>'));
      expect(opf, contains('<dc:language>zh</dc:language>'));
      final spine =
          RegExp(r'<spine[^>]*>(.*?)</spine>', dotAll: true).firstMatch(opf)!.group(1)!;
      final spineRefs = RegExp(r'idref="(chapter_\d+)"')
          .allMatches(spine)
          .map((m) => m.group(1)!)
          .toList();
      expect(spineRefs, ['chapter_0001', 'chapter_0002', 'chapter_0003']);
      // nav.xhtml 目录链接
      final nav = utf8.decode(archive.findFile('OEBPS/nav.xhtml')!.content);
      expect(nav, contains('第一章'));
      expect(nav, contains('chapter_0001.xhtml'));
      // toc.ncx（EPUB2 兼容）
      final ncx = utf8.decode(archive.findFile('OEBPS/toc.ncx')!.content);
      expect(ncx, contains('playOrder="1"'));
      expect(ncx, contains('第三章'));
      // 章节 xhtml 内容存在
      final ch1 =
          utf8.decode(archive.findFile('OEBPS/chapter_0001.xhtml')!.content);
      expect(ch1, contains('这是第一章的正文内容'));
      final ch3 =
          utf8.decode(archive.findFile('OEBPS/chapter_0003.xhtml')!.content);
      expect(ch3, contains('这是第三章的正文内容'));
    });

    test('EPUB 导出同样校验 meta sourceId', () async {
      await _cacheAllBook();
      final exporter = BookExporter(saveFile: _fakeSaveFile(tempDir));
      await expectLater(
        exporter.exportEpub(
          bookId: 'book1',
          sourceId: 'other-src',
          bookName: '测试之书',
          chapters: (await _catalog()).chapters,
        ),
        throwsA(isA<ExportSourceMismatchException>()),
      );
    });
  });
}

Future<ChapterCatalog> _catalog() async {
  final repo = ReaderRepositoryImpl(
    client: _buildClient(),
    sourceRepo: _SourceRepo(_source),
  );
  return repo.getCatalog(
    bookId: 'book1',
    sourceId: 'cache-src',
    detailUrl: 'https://example.com/book/1',
  );
}
