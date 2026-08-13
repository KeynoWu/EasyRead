import 'dart:io';

import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/core/pagination/page_layout.dart';
import 'package:easy_read/features/reader/core/theme/reader_theme.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/domain/entities/chapter.dart';
import 'package:easy_read/features/reader/domain/entities/reading_progress.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
import 'package:easy_read/features/settings/domain/entities/chinese_conversion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

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

/// 注入固定章节的仓库替身：绕过真实网络/解析链路，
/// 让 loadChapter 能走到 _loadChineseMode 的持久化读取。
class _FakeRepo extends ReaderRepositoryImpl {
  _FakeRepo() : super(sourceRepo: _FakeSourceRepo());

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
      content: '这是一段用于简繁设置读取测试的正文内容。',
      index: chapterIndex,
      sourceId: sourceId,
    );
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async => null;

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

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init(
      Directory.systemTemp.createTempSync('reader_scope_settings_test').path,
    );
  });

  setUp(() async {
    final box = await Hive.openBox<dynamic>('reader_settings');
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  ProviderContainer makeContainer({ReaderRepositoryImpl? repo}) {
    return ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(
        repo ?? ReaderRepositoryImpl(sourceRepo: _FakeSourceRepo()),
      ),
    ]);
  }

  test('书本级设置优先于全局设置', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);

    // 全局范围写入 fontSize=18（裸 key）
    await notifier.loadPersistedSettings();
    notifier.updateLayout(const LayoutConfig(fontSize: 18));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 本书范围写入 fontSize=24（`b1|` 前缀 key）
    notifier.resetForBook('b1');
    notifier.setSettingsScope(SettingsScope.book);
    notifier.updateLayout(const LayoutConfig(fontSize: 24));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // b2 无书本级设置 → 回退全局 18
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b2',
    );
    expect(container2.read(readerProvider).layoutConfig.fontSize, 18);

    // b1 有书本级 24 → 优先于全局 18
    final container3 = makeContainer();
    addTearDown(container3.dispose);
    await container3.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b1',
    );
    expect(container3.read(readerProvider).layoutConfig.fontSize, 24);
  });

  test('无书本级设置时回退全局设置（全局兜底）', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();
    notifier.updateLayout(const LayoutConfig(
      fontSize: 20,
      lineHeight: 1.9,
      paragraphSpacing: 20,
      horizontalPadding: 28,
      fontWeight: FontWeight.w700,
      fontFamily: 'Georgia',
    ));
    // 等待 unawaited 的 Hive 写入完成
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b1',
    );
    final state = container2.read(readerProvider);
    expect(state.layoutConfig.fontSize, 20);
    expect(state.layoutConfig.lineHeight, 1.9);
    expect(state.layoutConfig.paragraphSpacing, 20);
    expect(state.layoutConfig.horizontalPadding, 28);
    expect(state.layoutConfig.fontWeight, FontWeight.w700);
    expect(state.layoutConfig.fontFamily, 'Georgia');
  });

  test('本书范围写入不污染全局 key', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();
    notifier.resetForBook('b1');
    notifier.setSettingsScope(SettingsScope.book);
    notifier.updateLayout(const LayoutConfig(fontSize: 22));
    notifier.switchTheme(ReaderThemes.themes[2]);
    notifier.switchMode(ReadingMode.scroll);
    notifier.switchPageTurnStyle(PageTurnStyle.cover);
    // 等待 unawaited 的 Hive 写入完成
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final box = await Hive.openBox<dynamic>('reader_settings');
    // 书本级 key 已写入
    expect(box.get('b1|fontSize'), 22.0);
    expect(box.get('b1|theme'), ReaderThemes.themes[2].name);
    expect(box.get('b1|readingMode'), ReadingMode.scroll.index);
    expect(box.get('b1|pageTurnStyle'), PageTurnStyle.cover.index);
    // 全局裸 key 未被写入（不污染）
    expect(box.get('fontSize'), isNull);
    expect(box.get('theme'), isNull);
    expect(box.get('readingMode'), isNull);
    expect(box.get('pageTurnStyle'), isNull);

    // 另一本书读到默认值（书本级不跨书泄漏）
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b2',
    );
    expect(
      container2.read(readerProvider).layoutConfig.fontSize,
      const LayoutConfig().fontSize,
    );
  });

  test('全局范围写入不污染本书 key', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();
    notifier.resetForBook('b1');
    // 默认全局范围
    notifier.updateLayout(const LayoutConfig(fontSize: 20));
    notifier.switchTheme(ReaderThemes.themes[1]);
    // 等待 unawaited 的 Hive 写入完成
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final box = await Hive.openBox<dynamic>('reader_settings');
    expect(box.get('fontSize'), 20.0);
    expect(box.get('theme'), ReaderThemes.themes[1].name);
    expect(box.get('b1|fontSize'), isNull);
    expect(box.get('b1|theme'), isNull);

    // b1 无书本级 → 读全局兜底
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b1',
    );
    expect(container2.read(readerProvider).layoutConfig.fontSize, 20);
    expect(
      container2.read(readerProvider).theme.name,
      ReaderThemes.themes[1].name,
    );
  });

  test('旧数据（仅全局裸 key）兼容读取', () async {
    // 直接写入旧版全局裸 key，模拟历史持久化数据
    final box = await Hive.openBox<dynamic>('reader_settings');
    await box.putAll({
      'fontSize': 25.0,
      'lineHeight': 1.8,
      'theme': ReaderThemes.themes[3].name,
      'readingMode': ReadingMode.scroll.index,
      'pageTurnStyle': PageTurnStyle.slide.index,
    });

    final container = makeContainer();
    addTearDown(container.dispose);
    await container.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b1',
    );
    final state = container.read(readerProvider);
    expect(state.layoutConfig.fontSize, 25);
    expect(state.layoutConfig.lineHeight, 1.8);
    expect(state.theme.name, ReaderThemes.themes[3].name);
    expect(state.readingMode, ReadingMode.scroll);
    expect(state.pageTurnStyle, PageTurnStyle.slide);
  });

  test('scope 切换后写入目标正确', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();
    notifier.resetForBook('b1');

    // 全局范围 → 裸 key
    notifier.updateLayout(const LayoutConfig(fontSize: 20));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 切到本书 → `b1|` 前缀 key
    notifier.setSettingsScope(SettingsScope.book);
    notifier.updateLayout(const LayoutConfig(fontSize: 26));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 切回全局 → 裸 key 更新，本书 key 不变
    notifier.setSettingsScope(SettingsScope.global);
    notifier.updateLayout(const LayoutConfig(fontSize: 21));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final box = await Hive.openBox<dynamic>('reader_settings');
    expect(box.get('fontSize'), 21.0);
    expect(box.get('b1|fontSize'), 26.0);

    // b1 读生效值：书本级 26 优先
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b1',
    );
    expect(container2.read(readerProvider).layoutConfig.fontSize, 26);

    // b2 读全局 21
    final container3 = makeContainer();
    addTearDown(container3.dispose);
    await container3.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b2',
    );
    expect(container3.read(readerProvider).layoutConfig.fontSize, 21);
  });

  test('换书时设置范围重置为全局', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();
    notifier.resetForBook('b1');
    notifier.setSettingsScope(SettingsScope.book);
    notifier.updateLayout(const LayoutConfig(fontSize: 30));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notifier.settingsScope, SettingsScope.book);

    // 换书：范围重置为全局，且不残留 b1 的范围状态
    notifier.resetForBook('b2');
    expect(notifier.settingsScope, SettingsScope.global);
    notifier.updateLayout(const LayoutConfig(fontSize: 17));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final box = await Hive.openBox<dynamic>('reader_settings');
    expect(box.get('fontSize'), 17.0);
    expect(box.get('b2|fontSize'), isNull);
    // 之前的本书设置保留，不随换书删除
    expect(box.get('b1|fontSize'), 30.0);
  });

  test('主题/阅读模式/翻页动画支持书本级覆盖', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();

    // 全局：主题 themes[1]
    notifier.switchTheme(ReaderThemes.themes[1]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 本书 b1：覆盖为主题 themes[2]、滚动模式、覆盖动画
    notifier.resetForBook('b1');
    notifier.setSettingsScope(SettingsScope.book);
    notifier.switchTheme(ReaderThemes.themes[2]);
    notifier.switchMode(ReadingMode.scroll);
    notifier.switchPageTurnStyle(PageTurnStyle.cover);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final box = await Hive.openBox<dynamic>('reader_settings');
    expect(box.get('theme'), ReaderThemes.themes[1].name);
    expect(box.get('b1|theme'), ReaderThemes.themes[2].name);
    expect(box.get('b1|readingMode'), ReadingMode.scroll.index);
    expect(box.get('b1|pageTurnStyle'), PageTurnStyle.cover.index);

    // b1 读到本书覆盖值
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b1',
    );
    expect(container2.read(readerProvider).theme.name, ReaderThemes.themes[2].name);
    expect(container2.read(readerProvider).readingMode, ReadingMode.scroll);
    expect(container2.read(readerProvider).pageTurnStyle, PageTurnStyle.cover);

    // b2 无覆盖 → 全局兜底（阅读模式/动画未在全局设置，回退默认）
    final container3 = makeContainer();
    addTearDown(container3.dispose);
    await container3.read(readerProvider.notifier).loadPersistedSettings(
      bookId: 'b2',
    );
    expect(container3.read(readerProvider).theme.name, ReaderThemes.themes[1].name);
    expect(container3.read(readerProvider).readingMode, ReadingMode.page);
    expect(container3.read(readerProvider).pageTurnStyle, PageTurnStyle.flip);
  });

  test('简繁转换支持书本级覆盖', () async {
    final container = makeContainer(repo: _FakeRepo());
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);

    // 全局范围：简繁=繁体（裸 key）
    await notifier.loadPersistedSettings();
    await notifier.setChineseMode(ChineseConversionMode.traditional);

    // 本书 b1：简繁=简体（书本级 key）
    notifier.resetForBook('b1');
    notifier.setSettingsScope(SettingsScope.book);
    await notifier.setChineseMode(ChineseConversionMode.simplified);

    final box = await Hive.openBox<dynamic>('reader_settings');
    expect(box.get('chineseMode'), ChineseConversionMode.traditional.index);
    expect(box.get('b1|chineseMode'), ChineseConversionMode.simplified.index);

    // b1 加载章节 → 生效书本级简体
    await notifier.loadChapter(bookId: 'b1', chapterIndex: 0, sourceId: 's1');
    expect(
      container.read(readerProvider).chineseMode,
      ChineseConversionMode.simplified,
    );

    // 换书 b2（无书本级）→ 回退全局繁体
    notifier.resetForBook('b2');
    await notifier.loadChapter(bookId: 'b2', chapterIndex: 0, sourceId: 's1');
    expect(
      container.read(readerProvider).chineseMode,
      ChineseConversionMode.traditional,
    );
  });

  test('hasBookSettings 判断书本级自定义值是否存在', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();

    expect(await notifier.hasBookSettings('b1'), isFalse);

    notifier.resetForBook('b1');
    notifier.setSettingsScope(SettingsScope.book);
    notifier.updateLayout(const LayoutConfig(fontSize: 22));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await notifier.hasBookSettings('b1'), isTrue);
    expect(await notifier.hasBookSettings('b2'), isFalse);
  });

  test('不传 bookId 时使用 resetForBook 设置的书本（阅读页路径）', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();
    notifier.resetForBook('b1');
    notifier.setSettingsScope(SettingsScope.book);
    notifier.updateLayout(const LayoutConfig(fontSize: 23));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 模拟阅读页打开流程：先 resetForBook 再无参 loadPersistedSettings
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    final notifier2 = container2.read(readerProvider.notifier);
    notifier2.resetForBook('b1');
    await notifier2.loadPersistedSettings();
    expect(container2.read(readerProvider).layoutConfig.fontSize, 23);
  });
}
