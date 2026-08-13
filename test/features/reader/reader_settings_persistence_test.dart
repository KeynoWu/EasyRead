import 'dart:io';

import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/core/pagination/page_layout.dart';
import 'package:easy_read/features/reader/core/theme/reader_theme.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
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

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init(
      Directory.systemTemp.createTempSync('reader_settings_test').path,
    );
  });

  setUp(() async {
    final box = await Hive.openBox<dynamic>('reader_settings');
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  ProviderContainer makeContainer() {
    return ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(
        ReaderRepositoryImpl(sourceRepo: _FakeSourceRepo()),
      ),
    ]);
  }

  test('排版/主题/阅读模式设置持久化并可跨会话恢复', () async {
    final container1 = makeContainer();
    addTearDown(container1.dispose);
    final notifier = container1.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();

    notifier.updateLayout(const LayoutConfig(
      fontSize: 24,
      lineHeight: 1.8,
      fontFamily: 'Georgia',
    ));
    notifier.switchTheme(ReaderThemes.themes[2]);
    notifier.switchMode(ReadingMode.scroll);
    // 等待 unawaited 的 Hive 写入完成
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings();
    final state = container2.read(readerProvider);
    expect(state.layoutConfig.fontSize, 24);
    expect(state.layoutConfig.lineHeight, 1.8);
    expect(state.layoutConfig.fontFamily, 'Georgia');
    expect(state.theme.name, ReaderThemes.themes[2].name);
    expect(state.readingMode, ReadingMode.scroll);
  });

  test('无持久化数据时保持默认设置', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await container.read(readerProvider.notifier).loadPersistedSettings();
    final state = container.read(readerProvider);
    expect(state.layoutConfig.fontSize, const LayoutConfig().fontSize);
    expect(state.layoutConfig.lineHeight, const LayoutConfig().lineHeight);
    expect(state.readingMode, ReadingMode.page);
  });
}
