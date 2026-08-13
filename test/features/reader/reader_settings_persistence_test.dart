import 'dart:io';

import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/reader/core/pagination/page_layout.dart';
import 'package:easy_read/features/reader/core/theme/reader_theme.dart';
import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:easy_read/features/reader/presentation/providers/reader_provider.dart';
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

  test('段距/页边距/字重设置持久化并可跨会话恢复', () async {
    final container1 = makeContainer();
    addTearDown(container1.dispose);
    final notifier = container1.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();

    notifier.updateLayout(const LayoutConfig(
      paragraphSpacing: 20,
      horizontalPadding: 28,
      fontWeight: FontWeight.w700,
    ));
    // 等待 unawaited 的 Hive 写入完成
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings();
    final state = container2.read(readerProvider);
    expect(state.layoutConfig.paragraphSpacing, 20);
    expect(state.layoutConfig.horizontalPadding, 28);
    expect(state.layoutConfig.fontWeight, FontWeight.w700);
  });

  test('调整字号不丢失段距/页边距/字重/衬线设置（防覆盖回归）', () async {
    final container1 = makeContainer();
    addTearDown(container1.dispose);
    final notifier = container1.read(readerProvider.notifier);
    await notifier.loadPersistedSettings();

    // 先设置段距/页边距/字重/衬线
    notifier.updateLayout(const LayoutConfig(
      paragraphSpacing: 20,
      horizontalPadding: 28,
      fontWeight: FontWeight.w700,
      fontFamily: 'Georgia',
    ));

    // 模拟面板"字号"滑杆 onChangeEnd：只改字号，其余字段必须透传，
    // 否则 updateLayout 整体替换 layoutConfig 会清空其他排版项
    final layout = container1.read(readerProvider).layoutConfig;
    notifier.updateLayout(LayoutConfig(
      fontSize: 24,
      lineHeight: layout.lineHeight,
      paragraphSpacing: layout.paragraphSpacing,
      horizontalPadding: layout.horizontalPadding,
      fontWeight: layout.fontWeight,
      fontFamily: layout.fontFamily,
    ));
    // 等待 unawaited 的 Hive 写入完成
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 重启后所有字段应完整保留
    final container2 = makeContainer();
    addTearDown(container2.dispose);
    await container2.read(readerProvider.notifier).loadPersistedSettings();
    final state = container2.read(readerProvider);
    expect(state.layoutConfig.fontSize, 24);
    expect(state.layoutConfig.paragraphSpacing, 20);
    expect(state.layoutConfig.horizontalPadding, 28);
    expect(state.layoutConfig.fontWeight, FontWeight.w700);
    expect(state.layoutConfig.fontFamily, 'Georgia');
  });
}
