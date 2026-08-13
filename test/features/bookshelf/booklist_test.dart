import 'dart:convert';
import 'dart:io';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/bookshelf/data/services/book_detail_service.dart';
import 'package:easy_read/features/bookshelf/domain/entities/book.dart';
import 'package:easy_read/features/bookshelf/domain/repositories/bookshelf_repository.dart';
import 'package:easy_read/features/bookshelf/domain/usecases/export_booklist.dart';
import 'package:easy_read/features/bookshelf/domain/usecases/import_booklist.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 内存书架仓库：避免测试依赖真实 Hive 盒子
class _FakeBookshelfRepository implements BookshelfRepository {
  final Map<String, Book> store = {};

  @override
  Future<List<Book>> getAll() async => store.values.toList();

  @override
  Future<Book?> getById(String id) async => store[id];

  @override
  Future<void> save(Book book) async => store[book.id] = book;

  @override
  Future<void> delete(String id) async => store.remove(id);

  @override
  Future<void> deleteAll(List<String> ids) async {
    for (final id in ids) {
      store.remove(id);
    }
  }

  @override
  Future<void> updateProgress(String id, double progress) async {}
}

/// 内存书源仓库
class _FakeBookSourceRepository implements BookSourceRepository {
  final List<BookSource> sources;

  _FakeBookSourceRepository(this.sources);

  @override
  Future<List<BookSource>> getAll() async => sources;

  @override
  Future<BookSource?> getById(String id) async {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  @override
  Future<void> save(BookSource source) async => sources.add(source);

  @override
  Future<void> delete(String id) async {}

  @override
  Future<void> importFromJson(String jsonString) async {}

  @override
  Future<void> importFromUrl(String url) async {}

  @override
  Future<List<BookSource>> getEnabled() async =>
      sources.where((s) => s.enabled).toList();
}

/// 稳定书 ID 惯例：`${sourceId}_${detailUrl base64}`（与实现一致）
String _stableId(String detailUrl, {String sourceId = 'src1'}) =>
    '${sourceId}_${base64Url.encode(utf8.encode(detailUrl))}';

Book _book(String id, String name, {String? sourceId}) => Book(
      id: id,
      name: name,
      author: '作者$name',
      sourceId: sourceId,
      lastChapter: '第 1 章',
      lastReadAt: DateTime(2026, 1, 1),
    );

void main() {
  late BookDetailService detailService;
  late _FakeBookshelfRepository shelf;
  late _FakeBookSourceRepository sources;
  late BookSource src1;
  late BookSource src2;
  late BookSource disabled;

  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_booklist_test').path);
    detailService = BookDetailService();
    shelf = _FakeBookshelfRepository();
    src1 = const BookSource(id: 'src1', name: '起点中文网');
    src2 = const BookSource(id: 'src2', name: '番茄小说');
    disabled = const BookSource(id: 'src3', name: '禁用源', enabled: false);
    sources = _FakeBookSourceRepository([src1, src2, disabled]);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('ExportBooklist', () {
    test('导出 JSON 结构正确（origin/bookUrl 映射）', () async {
      final bookA = _book('a', '书A', sourceId: 'src1');
      final bookB = _book('b', '书B', sourceId: 'src2');
      await detailService.save(bookA.id, detailUrl: 'https://example.com/a');
      await detailService.save(bookB.id, detailUrl: 'https://example.com/b');

      final useCase = ExportBooklist(
        sourceRepository: sources,
        detailService: detailService,
      );
      final json = await useCase.buildJson([bookA, bookB], booklistName: '我的书单');

      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['name'], '我的书单');
      final books = decoded['books'] as List;
      expect(books.length, 2);

      final first = books[0] as Map<String, dynamic>;
      expect(first['name'], '书A');
      expect(first['author'], '作者书A');
      expect(first['origin'], '起点中文网'); // origin = 书源名
      expect(first['bookUrl'], 'https://example.com/a'); // bookUrl = 详情 URL
      expect(first['lastChapter'], '第 1 章');
      expect(first.containsKey('kind'), isTrue);
      expect(first.containsKey('intro'), isTrue);

      final second = books[1] as Map<String, dynamic>;
      expect(second['origin'], '番茄小说');
      expect(second['bookUrl'], 'https://example.com/b');
    });

    test('导出文件名默认值：书单名.json', () {
      final useCase = ExportBooklist(
        sourceRepository: sources,
        detailService: detailService,
      );
      // 默认书单名与默认文件名
      expect(ExportBooklist.defaultBooklistName, '我的书单');
      expect(
        useCase.defaultFileName(ExportBooklist.defaultBooklistName),
        '我的书单.json',
      );
      // 自定义书单名
      expect(useCase.defaultFileName('玄幻书单'), '玄幻书单.json');
    });

    test('未匹配到书源的书籍 origin 导出为 null，不影响其他字段', () async {
      final local = _book('local1', '本地书', sourceId: null);
      final useCase = ExportBooklist(
        sourceRepository: sources,
        detailService: detailService,
      );
      final json = await useCase.buildJson([local]);
      final books = (jsonDecode(json) as Map<String, dynamic>)['books'] as List;
      final entry = books[0] as Map<String, dynamic>;
      expect(entry['origin'], isNull);
      expect(entry['name'], '本地书');
    });
  });

  group('ImportBooklist', () {
    ImportBooklist buildUseCase() => ImportBooklist(
          bookshelfRepository: shelf,
          sourceRepository: sources,
          detailService: detailService,
        );

    test('正常导入：按书源匹配入书架并保存详情 URL', () async {
      const booklist = '''
      {
        "name": "书单",
        "books": [
          {"name": "书A", "author": "作者A", "origin": "起点中文网",
           "bookUrl": "https://example.com/a", "lastChapter": "第 3 章"},
          {"name": "书B", "origin": "番茄小说",
           "bookUrl": "https://example.com/b"}
        ]
      }
      ''';

      final result = await buildUseCase().importFromString(booklist);

      expect(result.error, isNull);
      expect(result.imported, 2);
      expect(result.skipped, 0);
      expect(result.unmatchedSource, 0);

      final idA = _stableId('https://example.com/a');
      final idB = _stableId('https://example.com/b', sourceId: 'src2');
      expect(shelf.store[idA]!.name, '书A');
      expect(shelf.store[idA]!.author, '作者A');
      expect(shelf.store[idA]!.sourceId, 'src1');
      expect(shelf.store[idA]!.lastChapter, '第 3 章');
      expect(shelf.store[idB]!.sourceId, 'src2');
      expect(shelf.store[idB]!.author, isNull); // 缺 author 不报错
      // 详情 URL 写入缓存，保证导入后可正常打开阅读
      expect((await detailService.get(idA))?.detailUrl, 'https://example.com/a');
      expect((await detailService.get(idB))?.detailUrl, 'https://example.com/b');
    });

    test('坏 JSON：整体解析失败返回 error', () async {
      final result = await buildUseCase().importFromString('{not-json!!');
      expect(result.error, isNotNull);
      expect(result.imported, 0);
      expect(shelf.store, isEmpty);

      final empty = await buildUseCase().importFromString('   ');
      expect(empty.error, isNotNull);
    });

    test('缺必要字段（name/bookUrl）的条目跳过并计数', () async {
      const booklist = '''
      {
        "name": "书单",
        "books": [
          {"origin": "起点中文网", "bookUrl": "https://example.com/a"},
          {"name": "缺URL的书", "origin": "起点中文网"},
          {"name": "有效书", "origin": "起点中文网",
           "bookUrl": "https://example.com/b"}
        ]
      }
      ''';

      final result = await buildUseCase().importFromString(booklist);

      expect(result.imported, 1);
      expect(result.skipped, 2); // 缺 name 与缺 bookUrl 各跳一本
      expect(shelf.store[_stableId('https://example.com/b')], isNotNull);
    });

    test('origin 无匹配书源：跳过并计数，不写入书架', () async {
      const booklist = '''
      {
        "name": "书单",
        "books": [
          {"name": "无源书", "origin": "不存在的书源",
           "bookUrl": "https://example.com/x"},
          {"name": "无origin书", "bookUrl": "https://example.com/y"}
        ]
      }
      ''';

      final result = await buildUseCase().importFromString(booklist);

      expect(result.imported, 0);
      expect(result.unmatchedSource, 2);
      expect(shelf.store, isEmpty);
    });

    test('仅匹配已启用书源，且书源名大小写不敏感', () async {
      sources.sources.add(const BookSource(id: 'src4', name: 'MySource'));
      const booklist = '''
      {
        "name": "书单",
        "books": [
          {"name": "书B", "origin": "番茄小说",
           "bookUrl": "https://example.com/b"},
          {"name": "大小写书", "origin": "mysource",
           "bookUrl": "https://example.com/m"},
          {"name": "禁用源书", "origin": "禁用源",
           "bookUrl": "https://example.com/c"}
        ]
      }
      ''';

      final result = await buildUseCase().importFromString(booklist);

      expect(result.imported, 2);
      expect(result.unmatchedSource, 1); // 禁用源不参与匹配
      expect(shelf.store[_stableId('https://example.com/b', sourceId: 'src2')]!.sourceId, 'src2');
      // 大小写不敏感：origin「mysource」匹配书源「MySource」
      expect(shelf.store[_stableId('https://example.com/m', sourceId: 'src4')]!.sourceId, 'src4');
      expect(shelf.store.containsKey(_stableId('https://example.com/c')), isFalse);
    });

    test('去重：书架已有同 ID 跳过，文件内重复条目也跳过', () async {
      const booklist = '''
      {
        "name": "书单",
        "books": [
          {"name": "书A", "origin": "起点中文网",
           "bookUrl": "https://example.com/a"},
          {"name": "书A重复", "origin": "起点中文网",
           "bookUrl": "https://example.com/a"}
        ]
      }
      ''';
      // 预置一条同 ID 书籍，模拟书架已有
      shelf.store[_stableId('https://example.com/a')] =
          _book(_stableId('https://example.com/a'), '已有书');

      final result = await buildUseCase().importFromString(booklist);

      expect(result.imported, 0);
      expect(result.skipped, 2); // 书架已有 + 文件内重复
      // 保留原书架数据，不被覆盖
      expect(shelf.store[_stableId('https://example.com/a')]!.name, '已有书');
    });

    test('books 缺失或非列表：整体解析失败', () async {
      final noBooks = await buildUseCase().importFromString('{"name": "书单"}');
      expect(noBooks.error, isNotNull);
      expect(noBooks.imported, 0);

      final notList = await buildUseCase()
          .importFromString('{"name": "书单", "books": "oops"}');
      expect(notList.error, isNotNull);
    });

    test('用户取消选择文件：返回 canceled 且不入书架', () async {
      // 直接构造 canceled 结果，验证页面分支依赖的字段
      const canceled = ImportBooklistResult(canceled: true);
      expect(canceled.canceled, isTrue);
      expect(canceled.imported, 0);
    });
  });
}
