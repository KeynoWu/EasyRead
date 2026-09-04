import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:easy_read/features/reader/presentation/widgets/cover_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CapturingClient implements DioClient {
  _CapturingClient({this.bytes, this.throwError = false});

  final Uint8List? bytes;
  final bool throwError;
  int calls = 0;
  String? lastUrl;
  Map<String, String>? lastHeaders;
  String? lastSourceId;

  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    calls++;
    lastUrl = url;
    lastHeaders = headers;
    lastSourceId = sourceId;
    if (throwError) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: url),
        reason: 'blocked',
      );
    }
    return bytes ?? Uint8List(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SourceRepo implements BookSourceRepository {
  _SourceRepo(this.source);

  final BookSource? source;

  @override
  Future<BookSource?> getById(String id) async => source;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

BookSource _sourceWithHeaders() => const BookSource(
      id: 'src1',
      name: '测试源',
      bookSourceUrl: 'https://source.example',
      rules: <String, dynamic>{
        'header': '{"Referer":"https://source.example/","X-Auth":"token1"}',
      },
    );

void main() {
  test('§三-3 fetchImageBytes 带书源 headers 并解析相对 URL', () async {
    final client = _CapturingClient();
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(_sourceWithHeaders()),
    );

    await repo.fetchImageBytes('/covers/1.jpg', sourceId: 'src1');

    expect(client.calls, 1);
    expect(client.lastUrl, 'https://source.example/covers/1.jpg');
    // 书源 requestHeaders（header 规则 + Referer 兜底）透传
    expect(client.lastHeaders!['Referer'], 'https://source.example/');
    expect(client.lastHeaders!['X-Auth'], 'token1');
    expect(client.lastSourceId, 'src1');
  });

  test('§三-3 无 sourceId 直取原 URL 且不带书源头', () async {
    final client = _CapturingClient();
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(null),
    );

    await repo.fetchImageBytes('https://img.example/a.jpg');

    expect(client.lastUrl, 'https://img.example/a.jpg');
    expect(client.lastHeaders ?? {}, isEmpty);
    expect(client.lastSourceId, isNull);
  });

  testWidgets('§三-3 CoverImage 加载成功渲染图片', (tester) async {
    // 1x1 PNG
    const pngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    final client = _CapturingClient(
      bytes: Uint8List.fromList(base64Decode(pngBase64)),
    );
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(_sourceWithHeaders()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [readerRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          home: Scaffold(
            body: CoverImage(
              url: 'https://img.example/ok.jpg',
              sourceId: 'src1',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(client.lastHeaders!['Referer'], 'https://source.example/');
  });

  testWidgets('§三-3 CoverImage 加载失败显示占位且失败 URL 不再请求', (tester) async {
    final client = _CapturingClient(throwError: true);
    final repo = ReaderRepositoryImpl(
      client: client,
      sourceRepo: _SourceRepo(null),
    );

    const failedUrl = 'https://blocked.example/fail.jpg';
    final widget = ProviderScope(
      overrides: [readerRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(
        home: Scaffold(body: CoverImage(url: failedUrl)),
      ),
    );
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.auto_stories), findsOneWidget);
    expect(client.calls, 1);

    // 失败后再挂同一 URL：会话内不再重复请求（防请求风暴）
    await tester.pumpWidget(
      ProviderScope(
        overrides: [readerRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CoverImage(url: failedUrl),
                CoverImage(url: failedUrl),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.calls, 1);
  });
}
