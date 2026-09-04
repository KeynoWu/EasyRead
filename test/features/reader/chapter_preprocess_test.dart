import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/core/purification/purify_pipeline.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/settings/domain/entities/chinese_conversion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 可编程 mock：按 URL 前缀决定响应；chapter 前缀可配置先失败 N 次
class _StatefulClient implements DioClient {
  _StatefulClient();

  /// 正文页请求先抛 DioException 的次数
  int failChapterTimes = 0;
  int chapterFetches = 0;

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
      chapterFetches++;
      if (failChapterTimes > 0) {
        failChapterTimes--;
        throw DioException.connectionError(
          requestOptions: RequestOptions(path: url),
          reason: 'timeout',
        );
      }
      return '<div class="content">正文內容</div>';
    }
    // 详情页：目录
    return '<ul><li><a href="https://example.com/ch/1">第一章</a></li></ul>';
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

BookSource _sourceWith(String purifyPattern) => const BookSource(
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
    Hive.init(Directory.systemTemp.createTempSync('hive_preprocess').path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(ChapterModelAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  PurifyPipeline makePipeline(String pattern, String replacement) => PurifyPipeline(
        regexPurifier: RegexPurifier(
          rules: [PurifyRule(pattern: pattern, replacement: replacement)],
        ),
      );

  test('§三-11 简繁转换在净化规则前：繁体站配简体规则可命中', () async {
    final repo = ReaderRepositoryImpl(
      client: _StatefulClient(),
      sourceRepo: _SourceRepo(_sourceWith('')),
      pipeline: makePipeline('正文内容', '净化完成'),
    );

    final chapter = await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
      chineseMode: ChineseConversionMode.simplified,
    );
    // 繁体「正文內容」先转简体「正文内容」，再命中净化规则
    expect(chapter.content, '净化完成');
  });

  test('§三-11 默认原文模式不转换，繁体内容不命中简体规则', () async {
    final repo = ReaderRepositoryImpl(
      client: _StatefulClient(),
      sourceRepo: _SourceRepo(_sourceWith('')),
      pipeline: makePipeline('正文内容', '净化完成'),
    );

    final chapter = await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    expect(chapter.content, '正文內容');
  });

  test('§三-12 正文页瞬时网络异常重试后成功（3 次上限内）', () async {
    final client = _StatefulClient()
      ..failChapterTimes = 2;
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(_sourceWith('')),
      contentRetryInterval: const Duration(milliseconds: 5),
    );

    final chapter = await repo.getChapter(
      bookId: 'book1',
      chapterIndex: 0,
      sourceId: 'src1',
      detailUrl: 'https://example.com/book/1',
    );
    expect(chapter.content, contains('正文'));
    // 前 2 次失败 + 第 3 次成功
    expect(client.chapterFetches, 3);
  });

  test('§三-12 重试次数耗尽仍失败则抛错（网络类）', () async {
    final client = _StatefulClient()
      ..failChapterTimes = 99;
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(_sourceWith('')),
      contentRetryInterval: const Duration(milliseconds: 5),
    );

    await expectLater(
      repo.getChapter(
        bookId: 'book1',
        chapterIndex: 0,
        sourceId: 'src1',
        detailUrl: 'https://example.com/book/1',
      ),
      throwsA(
        isA<ChapterLoadException>()
            .having((e) => e.kind, 'kind', ChapterErrorKind.networkError),
      ),
    );
    // 初始 1 次 + 重试 3 次 = 4 次请求
    expect(client.chapterFetches, 4);
  });
}
