import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _OnceClient implements DioClient {
  _OnceClient();

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
      getString(url);

  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> getString(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    if (url.contains('/ch/')) {
      return '<div class="content">${'正文字符' * 30}</div>';
    }
    // 详情页：目录（两个章节）
    return '<ul><li><a href="https://example.com/ch/1">第一章</a></li>'
        '<li><a href="https://example.com/ch/2">第二章</a></li></ul>';
  }

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

const _source = BookSource(
  id: 'src1',
  name: '测试源',
  bookSourceUrl: 'https://example.com',
  rules: <String, dynamic>{
    'chapterList': 'ul > li',
    'chapterName': 'a',
    'chapterUrl': 'a@href',
    'chapterContent': 'div.content@text',
  },
);

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_byte_budget').path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(ChapterModelAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('§三-6 章节缓存超字节预算时淘汰最旧条目', () async {
    final repo = ReaderRepositoryImpl(
      client: _OnceClient(),
      sourceRepo: _SourceRepo(_source),
      // 每章正文约 120 字符，预算只容 1 章
      cacheByteBudget: 150,
    );

    await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 1,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );

    final box = await Hive.openBox<ChapterModel>('chapters');
    // 预算 150 容不下两章：最旧的 ch0 被淘汰，ch1 保留
    expect(box.values.length, 1);
    expect(box.values.first.content, contains('正文字符'));
    expect(box.values.first.id, contains('_1'));
  });

  test('§三-6 预算内不淘汰', () async {
    final repo = ReaderRepositoryImpl(
      client: _OnceClient(),
      sourceRepo: _SourceRepo(_source),
    );

    await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 1,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );

    final box = await Hive.openBox<ChapterModel>('chapters');
    expect(box.values.length, 2);
  });
}
