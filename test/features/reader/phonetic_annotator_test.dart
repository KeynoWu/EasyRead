import 'dart:io';

import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/core/pagination/phonetic_annotator.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:easy_read/features/reader/presentation/widgets/page_view_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  const style = TextStyle(fontSize: 16, height: 1.6, color: Colors.black);
  const muted = Color(0x73000000);

  group('PhoneticAnnotator 分词与注音', () {
    test('常用字不注音：连续常用字合并为单个 TextSpan', () {
      final spans = PhoneticAnnotator.annotate(
        '你好世界',
        style: style,
        annotationColor: muted,
      );
      expect(spans, hasLength(1));
      expect(spans.single, isA<TextSpan>());
      expect((spans.single as TextSpan).text, '你好世界');
    });

    test('生僻字注音：龘 生成 WidgetSpan，内含 dá 小字与原字', () {
      final spans = PhoneticAnnotator.annotate(
        '龘',
        style: style,
        annotationColor: muted,
      );
      expect(spans, hasLength(1));
      final span = spans.single;
      expect(span, isA<WidgetSpan>());
      final texts = _collectTexts((span as WidgetSpan).child);
      expect(texts.map((t) => t.data).toList(), ['dá', '龘']);
      // 拼音样式：40% 字号、弱化颜色、紧凑行高
      final pinyinStyle = texts[0].style!;
      expect(pinyinStyle.fontSize, closeTo(16 * 0.4, 0.001));
      expect(pinyinStyle.color, muted);
      expect(pinyinStyle.height, 1.0);
      // 原字样式继承正文（字号/颜色不变，行高压缩避免 Column 内部撑高）
      final charStyle = texts[1].style!;
      expect(charStyle.fontSize, 16);
      expect(charStyle.color, Colors.black);
      expect(charStyle.height, 1.0);
    });

    test('混合文本分段正确：生僻字拆出，常用字与标点各成段', () {
      final spans = PhoneticAnnotator.annotate(
        '龘你好犇！',
        style: style,
        annotationColor: muted,
      );
      expect(spans, hasLength(4));
      expect(spans[0], isA<WidgetSpan>()); // 龘
      expect(spans[1], isA<TextSpan>());
      expect((spans[1] as TextSpan).text, '你好');
      expect(spans[2], isA<WidgetSpan>()); // 犇
      expect(spans[3], isA<TextSpan>());
      expect((spans[3] as TextSpan).text, '！'); // 生僻字后标点另起一段
    });

    test('非 CJK 原样合并', () {
      final spans = PhoneticAnnotator.annotate(
        'abc 123 !@#',
        style: style,
        annotationColor: muted,
      );
      expect(spans, hasLength(1));
      expect((spans.single as TextSpan).text, 'abc 123 !@#');
    });

    test('CJK 但无拼音映射：原样输出不注音', () {
      final spans = PhoneticAnnotator.annotate(
        '𰀀',
        style: style,
        annotationColor: muted,
      );
      expect(spans, hasLength(1));
      expect(spans.single, isA<TextSpan>());
      expect((spans.single as TextSpan).text, '𰀀');
    });

    test('常用字表外的多个生僻字各自注音', () {
      final spans = PhoneticAnnotator.annotate(
        '犇焱燚',
        style: style,
        annotationColor: muted,
      );
      expect(spans, hasLength(3));
      for (final span in spans) {
        expect(span, isA<WidgetSpan>());
      }
      final first = _collectTexts((spans[0] as WidgetSpan).child);
      expect(first.map((t) => t.data).toList(), ['bēn', '犇']);
    });

    test('空文本返回空列表', () {
      expect(
        PhoneticAnnotator.annotate('', style: style, annotationColor: muted),
        isEmpty,
      );
    });
  });

  group('PhoneticAnnotator 渲染（widget 层）', () {
    testWidgets('生僻字上方渲染小字拼音，常用字与原字正常显示', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhoneticAnnotator.annotatedText(
              '龘你好',
              style: style,
              annotationColor: muted,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('dá'), findsOneWidget);
      expect(find.text('龘'), findsOneWidget);
      // 常用字保留为 RichText 中的连续 TextSpan（含 WidgetSpan 时
      // findRichText 的 toPlainText 不可用，改断言 span 结构）
      final rich = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
      );
      final rootSpan = rich.textSpan! as TextSpan;
      expect(rootSpan.children, hasLength(2));
      expect((rootSpan.children![1] as TextSpan).text, '你好');
    });

    testWidgets('无生僻字时渲染为普通文本（与未注音路径等价）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhoneticAnnotator.annotatedText(
              '你好世界',
              style: style,
              annotationColor: muted,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('你好世界', findRichText: true), findsOneWidget);
    });
  });

  group('PhoneticSettings 持久化', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('phonetic_setting_test');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      PhoneticSettings.enabled.value = false; // 复位全局缓存，避免污染其他用例
      await Hive.deleteFromDisk();
    });

    test('默认关闭', () async {
      await PhoneticSettings.ensureLoaded();
      expect(PhoneticSettings.enabled.value, isFalse);
    });

    test('写入后模拟重启（同目录重开）仍为开启', () async {
      await PhoneticSettings.setEnabled(true);
      expect(PhoneticSettings.enabled.value, isTrue);
      await Hive.close();
      PhoneticSettings.enabled.value = false; // 清内存缓存，验证从磁盘恢复
      Hive.init(tempDir.path);
      await PhoneticSettings.ensureLoaded();
      expect(PhoneticSettings.enabled.value, isTrue);
    });

    test('写入关闭后重启仍为关闭', () async {
      await PhoneticSettings.setEnabled(true);
      await PhoneticSettings.setEnabled(false);
      await Hive.close();
      PhoneticSettings.enabled.value = true; // 清内存缓存
      Hive.init(tempDir.path);
      await PhoneticSettings.ensureLoaded();
      expect(PhoneticSettings.enabled.value, isFalse);
    });
  });

  group('ReaderPageView 集成（注音开关实时生效）', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      Hive.init(
        Directory.systemTemp.createTempSync('phonetic_reader_widget').path,
      );
    });

    setUp(() async {
      // 预开 reader_settings 盒：loadChapter 会同步读该盒，FakeAsync 内
      // 不能发起真实文件 I/O（会永久挂起），必须在真实异步窗口预开
      final box = await Hive.openBox<dynamic>('reader_settings');
      await box.clear();
    });

    tearDownAll(() async {
      PhoneticSettings.enabled.value = false;
      await Hive.close();
    });

    testWidgets('默认关闭渲染原样文本，开启后正文生僻字出现拼音', (tester) async {
      final container = ProviderContainer(overrides: [
        readerRepositoryProvider.overrideWithValue(
          _FakeChapterRepo(paragraphCount: 3),
        ),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(readerProvider.notifier);
      await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
      notifier.setViewport(400, 600);

      PhoneticSettings.enabled.value = false; // 默认关闭
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: ReaderPageView(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('dá'), findsNothing);
      // 关闭时是整段 Text，精确匹配不到单字，用包含匹配
      expect(find.textContaining('龘'), findsOneWidget);

      // 实时切换：不开设置页，仅翻转开关即应重建为注音渲染
      PhoneticSettings.enabled.value = true;
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('dá'), findsOneWidget);
      expect(find.text('龘'), findsOneWidget);
    });
  });
}

/// 递归收集 widget 树中所有 Text（跨 _NoBaseline 等包装结构），保持渲染顺序
List<Text> _collectTexts(Widget widget) {
  final out = <Text>[];
  void walk(Widget w) {
    if (w is Text) {
      out.add(w);
      return;
    }
    if (w is MultiChildRenderObjectWidget) {
      for (final c in w.children) {
        walk(c);
      }
    } else if (w is SingleChildRenderObjectWidget && w.child != null) {
      walk(w.child!);
    }
  }

  walk(widget);
  return out;
}

class _FakeSourceRepo implements BookSourceRepository {
  @override
  Future<List<BookSource>> getAll() async => [];

  @override
  Future<BookSource?> getById(String id) async => null;

  @override
  Future<void> save(BookSource source) async {}

  @override
  Future<void> delete(String id) async {}

  @override
  Future<void> importFromJson(String jsonString) async {}

  @override
  Future<void> importFromUrl(String url) async {}

  @override
  Future<List<BookSource>> getEnabled() async => [];
}

/// 注入固定章节的仓库替身：首段含生僻字「龘」，用于验证正文注音渲染链路
class _FakeChapterRepo extends ReaderRepositoryImpl {
  final int paragraphCount;
  _FakeChapterRepo({this.paragraphCount = 60})
      : super(sourceRepo: _FakeSourceRepo());

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {
    return Chapter(
      id: '$bookId#$chapterIndex',
      bookId: bookId,
      title: '第${chapterIndex + 1}章',
      content: List.generate(
        paragraphCount,
        (i) => i == 0
            ? '<p>这是第1段用于分页测试的龘正文内容，包含足够多的文字以保证分页引擎能把章节切分成多页。</p>'
            : '<p>这是第${i + 1}段用于分页测试的正文内容，包含足够多的文字以保证分页引擎能把章节切分成多页。</p>',
      ).join(),
      index: chapterIndex,
      sourceId: sourceId,
    );
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> saveProgress(ReadingProgress progress) async {}

  @override
  Future<void> preloadChapters({
    required String bookId,
    required int startIndex,
    required int count,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  }) async {}
}
