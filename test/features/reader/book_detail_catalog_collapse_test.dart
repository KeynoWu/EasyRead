import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/book_detail.dart';
import 'package:easy_read/features/reader/domain/entities/chapter_catalog.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/presentation/pages/book_detail_page.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 手写 fake：只覆盖详情页 _load 用到的三个方法，
/// 其余继承真实实现（不会被调用）。
class _FakeReaderRepo extends ReaderRepositoryImpl {
  @override
  Future<BookDetail> getBookDetail({
    required String bookId,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return const BookDetail(
      bookId: 'b1',
      name: '测试书',
      intro: '这是一段简介。',
    );
  }

  @override
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return ChapterCatalog(
      bookId: 'b1',
      fetchedAt: DateTime(2026, 1, 1),
      chapters: const [
        ChapterItem(title: '第一章', url: 'u1', index: 0),
        ChapterItem(title: '第二章', url: 'u2', index: 1),
      ],
    );
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => null;
}

void main() {
  const fakeResult = SearchResult(
    bookId: 'b1',
    name: '测试书',
    author: '作者',
    detailUrl: 'https://example.com/book/1',
    sourceId: 's1',
    sourceName: '测试源',
  );

  testWidgets('详情页目录默认折叠：只显示标题，点击展开章节，再点收起', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [readerRepositoryProvider.overrideWithValue(_FakeReaderRepo())],
        child: const MaterialApp(home: BookDetailPage(result: fakeResult)),
      ),
    );
    await tester.pumpAndSettle();

    // 默认折叠：有目录标题与展开箭头，但没有章节项
    expect(find.text('目录（2）'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.text('第一章'), findsNothing);
    expect(find.text('第二章'), findsNothing);

    // 点击标题展开：章节项出现，箭头翻转
    await tester.tap(find.text('目录（2）'));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    // 再点收起
    await tester.tap(find.text('目录（2）'));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });
}
