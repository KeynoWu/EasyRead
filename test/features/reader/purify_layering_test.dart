import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_read/core/database/hive_init.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/core/purification/purify_pipeline.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:hive/hive.dart';

class _StaticClient implements DioClient {
  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> requestString(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    int retry = 0,
    CancelToken? cancelToken,
  }) async =>
      '<div class="content">正文内容</div>';

  @override
  Dio get dio => Dio();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SourceRepo implements BookSourceRepository {
  _SourceRepo(this.source);

  final BookSource source;

  @override
  Future<BookSource?> getById(String id) async => source;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

PurifyPipeline _pipeline(String replacement) => PurifyPipeline(
      regexPurifier: RegexPurifier(
        rules: [PurifyRule(pattern: '正文', replacement: replacement)],
      ),
      titlePurifier: const RegexPurifier(
        rules: [PurifyRule(pattern: '第1章', replacement: '卷一')],
      ),
    );

const _source = BookSource(
  id: 'src1',
  name: '测试源',
  bookSourceUrl: 'https://example.com',
  rules: <String, dynamic>{
    'chapterContent': 'div.content@text',
  },
);

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_purify_layer').path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(ChapterModelAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('§三-1 缓存存源规则后原文，用户净化规则阅读时套用', () async {
    final repo = ReaderRepositoryImpl(
      client: _StaticClient(),
      sourceRepo: _SourceRepo(_source),
      pipeline: _pipeline('净化'),
    );

    final chapter = await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    // 返回值为用户规则净化后的内容
    expect(chapter.content, '净化内容');
    expect(chapter.title, '卷一');

    // 缓存里是源规则后原文（未套用户规则）
    final box = await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
    final cached = box.values.single;
    expect(cached.content, '正文内容');
    expect(cached.content.contains('净化'), isFalse);
    expect(cached.title, '第1章');
  });

  test('§三-1 修改用户净化规则无需清缓存即生效（阅读时套用）', () async {
    final repoA = ReaderRepositoryImpl(
      client: _StaticClient(),
      sourceRepo: _SourceRepo(_source),
      pipeline: _pipeline('净化'),
    );
    final first = await repoA.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    expect(first.content, '净化内容');

    // 同一 Hive 目录（同一缓存），换新规则实例模拟用户改规则
    final repoB = ReaderRepositoryImpl(
      client: _StaticClient(),
      sourceRepo: _SourceRepo(_source),
      pipeline: _pipeline('改规则生效'),
    );
    final second = await repoB.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    // 缓存命中（原文仍在），阅读时按新规则重新净化
    expect(second.content, '改规则生效内容');
  });
}
