import 'dart:io';

import 'package:easy_read/features/search/data/services/search_history_service.dart';
import 'package:easy_read/features/search/domain/usecases/search_books.dart';
import 'package:easy_read/features/search/presentation/pages/search_page.dart';
import 'package:easy_read/features/search/presentation/providers/search_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('search_hotwords_test').path);
    // 预开搜索历史箱：widget 内 getRecent() 走同步"已开箱"路径，
    // 避免 FakeAsync 中发起真实文件 I/O 留下悬挂的 openBox Future
    await SearchHistoryService().getRecent();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  /// 空态搜索页：搜索流与可搜索源数均用假实现，避免真实网络/Hive 依赖
  Widget buildSearchPage() {
    return ProviderScope(
      overrides: [
        searchResultsProvider.overrideWith(
          (ref, arg) => Stream.value(SearchProgress.empty),
        ),
        enabledSearchableCountProvider.overrideWith((ref) async => 0),
      ],
      child: const MaterialApp(home: SearchPage()),
    );
  }

  test('热门搜索为文件内 const 列表：10 个通用引导词，无重复、不含具体书名', () {
    expect(hotSearchWords, isA<List<String>>());
    expect(hotSearchWords.length, 10);
    expect(hotSearchWords, [
      '玄幻', '都市', '科幻', '悬疑', '言情', '历史', '完本', '连载', '排行榜', '免费',
    ]);
    for (final word in hotSearchWords) {
      expect(word.trim().isNotEmpty, isTrue);
    }
    expect(hotSearchWords.toSet().length, hotSearchWords.length);
  });

  testWidgets('空态显示热门搜索区块（10 个引导词 chip），无历史时不显示历史区块', (tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pump();

    expect(find.text('热门搜索'), findsOneWidget);
    for (final word in hotSearchWords) {
      expect(find.text(word), findsOneWidget);
    }
    expect(find.text('搜索历史'), findsNothing);
  });

  testWidgets('点击热词 chip：填入搜索框并立即触发搜索，热门搜索区块隐藏', (tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pump();

    // 在 runAsync（真实异步区）内点击：_startSearch 内部 fire-and-forget 的
    // 历史写入（Hive 文件 I/O）才能真正完成，避免悬挂导致 tearDown 卡死；
    // 轮询等待历史落盘，同时验证点击确实走了真实搜索链路
    await tester.runAsync(() async {
      await tester.tap(find.text('玄幻'));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if ((await SearchHistoryService().getRecent()).contains('玄幻')) return;
      }
    });
    await tester.pumpAndSettle();

    // 输入框已同步为热词
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller!.text, '玄幻');
    // 空态区块不再显示，进入搜索流程（假流立即完成且无结果）
    expect(find.text('热门搜索'), findsNothing);
    expect(find.text('未找到相关书籍'), findsOneWidget);
  });

  testWidgets('有搜索历史时：历史在上、热门搜索在下', (tester) async {
    // 预写历史：真实异步读写需在 runAsync 中完成
    await tester.runAsync(() async {
      await SearchHistoryService().add('武侠');
    });

    await tester.pumpWidget(buildSearchPage());
    await tester.pump();
    await tester.pump();

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('武侠'), findsOneWidget);
    final historyY = tester.getTopLeft(find.text('搜索历史')).dy;
    final hotwordsY = tester.getTopLeft(find.text('热门搜索')).dy;
    expect(historyY, lessThan(hotwordsY));
  });
}
