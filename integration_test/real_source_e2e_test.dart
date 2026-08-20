import 'dart:io';

import 'package:easy_read/app.dart';
import 'package:easy_read/core/database/hive_init.dart';
import 'package:easy_read/features/book_source/data/models/book_source_model.dart';
import 'package:easy_read/features/book_source/data/repositories/book_source_repository_impl.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/usecases/import_book_source.dart';
import 'package:easy_read/features/book_source/domain/usecases/parse_book_source_rule.dart';
import 'package:easy_read/features/bookshelf/data/models/book_model.dart';
import 'package:easy_read/features/reader/data/models/chapter_model.dart';
import 'package:easy_read/features/reader/data/models/reading_progress_model.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/search/data/engines/rule_parser.dart';
import 'package:easy_read/features/search/data/repositories/search_repository_impl.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:integration_test/integration_test.dart';

/// M1-5 真实书源端到端验收：
/// 真实网络导入书源 → 搜索 → 目录 → 正文，
/// 确认 M1 修复后「不再整页 HTML 兜底」：正文要么是干净文本，
/// 要么解析失败抛 ChapterLoadException（可重试），绝不返回整页 HTML。
///
/// 依赖真实网络与外部站点，失败可能是站点反爬/网络波动而非代码缺陷；
/// 判定标准是行为契约（无整页 HTML 兜底），而非具体某站可用。
const String _sourceUrl = 'https://legado.aoaostar.com/sources/71e56d4f.json';
const String _keyword = '诡秘之主';

/// 尝试书源搜索：非 JS 搜索规则优先（iOS 无 quickjs，JS 规则降级为空），
/// 且 curl 实测可用的源（2026-08-20）最优先，最多尝试 [_maxSourceTries] 个。
const int _maxSourceTries = 10;

/// 实测（curl 直连）验证过「搜索有结果且规则匹配当前页面结构」的源
const Set<String> _preferredSources = {'独步小说网', '阅友小说', '天天看小说'};

bool _isJsSearchRule(BookSource source) {
  return RuleParser.isJsRule(source.bookListRule ?? '') ||
      RuleParser.isJsRule(source.bookNameRule ?? '') ||
      RuleParser.isJsRule(source.searchUrl ?? '');
}

Future<({BookSource source, SearchResult result})?> _findSearchableSource(
  SearchRepositoryImpl searchRepo,
  List<BookSource> sources,
) async {
  final usable = sources
      .where((s) => s.searchUrl != null && s.bookListRule != null)
      .map((s) => _preferredSources.contains(s.name) && !s.enabled
          ? s.copyWith(enabled: true)
          : s);
  final candidates = usable.toList()
    ..sort((a, b) {
      final aPref = _preferredSources.contains(a.name) ? 0 : 1;
      final bPref = _preferredSources.contains(b.name) ? 0 : 1;
      if (aPref != bPref) return aPref - bPref;
      final aJs = _isJsSearchRule(a) ? 1 : 0;
      final bJs = _isJsSearchRule(b) ? 1 : 0;
      return aJs - bJs;
    });
  debugPrint('[e2e] 可用源 ${candidates.length} 个，尝试前 $_maxSourceTries 个'
      '（实测可用源优先，其次非 JS 规则）');
  for (final source in candidates.take(_maxSourceTries)) {
    if (!source.enabled) continue;
    final jsNote = _isJsSearchRule(source) ? ' [JS 规则, iOS 将降级]' : '';
    try {
      final results = await searchRepo
          .searchWithSource(_keyword, source)
          .timeout(const Duration(seconds: 45));
      final usableResults =
          results.where((r) => r.name.isNotEmpty && r.detailUrl != null);
      if (usableResults.isNotEmpty) {
        return (source: source, result: usableResults.first);
      }
      debugPrint('[e2e] 源 ${source.name}$jsNote 无结果，跳过');
    } catch (e) {
      debugPrint('[e2e] 源 ${source.name}$jsNote 搜索失败: $e');
    }
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    if (!kIsWeb) {
      final tempDir = Directory.systemTemp.createTempSync('itest_e2e');
      Hive.init(tempDir.path);
    }
    Hive.registerAdapter(BookModelAdapter());
    Hive.registerAdapter(BookSourceModelAdapter());
    Hive.registerAdapter(ChapterModelAdapter());
    Hive.registerAdapter(ReadingProgressModelAdapter());
    await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await openSensitiveBox<BookSourceModel>(HiveBoxes.bookSources);
    await openSensitiveBox(HiveBoxes.settings);
    await Hive.openBox<ChapterModel>(HiveBoxes.chapters);
    await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);
  });

  testWidgets(
    '真实书源：导入→搜索→目录→正文，正文不含整页 HTML 兜底',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: EasyReadApp()));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // 1. 真实 URL 导入书源（走 ImportBookSource 完整链路）
      final repo = BookSourceRepositoryImpl();
      final imported = await ImportBookSource(
        repository: repo,
        parser: ParseBookSourceRule(),
      ).fromUrl(_sourceUrl);
      expect(imported.isRight, isTrue,
          reason: '真实 URL 导入应成功: ${imported.isLeft ? imported.left : ''}');
      final sources = imported.right;
      expect(sources, isNotEmpty, reason: '导入结果不应为空');
      debugPrint('[e2e] 导入成功: ${sources.length} 个书源');

      // 2. 逐源搜索，找到第一个可用源
      final searchRepo = SearchRepositoryImpl();
      final found = await _findSearchableSource(searchRepo, sources);
      expect(found, isNotNull,
          reason: '前 5 个书源应至少有一个能搜到 "$_keyword"');
      final source = found!.source;
      final result = found.result;
      debugPrint('[e2e] 命中源: ${source.name}, 书: ${result.name}'
          ' (${result.author ?? '未知作者'})');
      expect(result.name, isNotEmpty);
      expect(result.detailUrl, isNotEmpty);

      // 3. 拉取目录
      final readerRepo = ReaderRepositoryImpl(sourceRepo: repo);
      final catalog = await readerRepo.getCatalog(
        bookId: result.bookId,
        sourceId: result.sourceId,
        detailUrl: result.detailUrl!,
        variables: result.variables,
      );
      expect(catalog.chapters, isNotEmpty,
          reason: '目录不应为空（站点可访问时）');
      debugPrint('[e2e] 目录: ${catalog.chapters.length} 章, '
          '首章: ${catalog.chapters.first.title}');

      // 4. 拉取第一章正文
      final first = catalog.chapters.first;
      late Chapter chapter;
      try {
        chapter = await readerRepo.getChapter(
          bookId: result.bookId,
          chapterIndex: first.index,
          sourceId: result.sourceId,
          detailUrl: result.detailUrl,
          variables: {...result.variables, ...first.variables},
        );
      } on ChapterLoadException catch (e) {
        fail('M1 契约：解析失败应抛 ChapterLoadException 且不含整页 HTML'
            ' 兜底。异常: $e');
      }

      // 5. 正文契约断言：M1 核心是「不再整页 HTML 兜底」。
      // Legado `@html` 正文规则允许保留正文容器/段落标签（如 <p>/<div>），
      // 由净化管线与渲染层处理；整页兜底的判据是文档级结构标签。
      final content = chapter.content;
      debugPrint('[e2e] 正文长度: ${content.length} 字符, '
          '标题: ${chapter.title}');
      expect(content, isNotEmpty, reason: '正文不应为空');
      expect(content.length, greaterThanOrEqualTo(200),
          reason: '真实正文应足够长（≥200 字）');
      final lower = content.toLowerCase();
      expect(lower.contains('<html'), isFalse,
          reason: '正文不应是整页 HTML 兜底');
      expect(lower.contains('<!doctype'), isFalse,
          reason: '正文不应含 DOCTYPE');
      expect(lower.contains('<head'), isFalse,
          reason: '正文不应含 head 结构');
      expect(lower.contains('<body'), isFalse,
          reason: '正文不应含 body 结构');
      expect(lower.contains('</html>'), isFalse,
          reason: '正文不应以 HTML 文档收尾');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
