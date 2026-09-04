import 'dart:async';

import 'package:hive/hive.dart';

import '../../../search/domain/entities/search_result.dart';
import '../entities/chapter_catalog.dart';
import '../repositories/reader_repository.dart';

/// 自动换源结果：可用的新书源及其目录
class AutoSwitchResult {
  final String sourceId;
  final String sourceName;
  final String? detailUrl;
  final ChapterCatalog catalog;

  const AutoSwitchResult({
    required this.sourceId,
    required this.sourceName,
    required this.detailUrl,
    required this.catalog,
  });
}

/// 自动换源用例（对齐 Legado ReadBookViewModel.autoChangeSource
/// mapParallelSafe(threadCount).take(1) 语义）：
/// 候选并发校验（默认 16），单个候选通过 = 目录非空 + 当前章正文可取；
/// 首个通过校验的候选胜出；全部失败返回 null。
class AutoSwitchSource {
  final ReaderRepository repository;

  const AutoSwitchSource({required this.repository});

  /// 校验并挑选替代书源：
  /// - 跳过当前书源、空标识、无详情页以及与当前详情页相同的源；
  /// - 每个源最多尝试一次；单源失败（含空目录、正文验证失败）即弃；
  /// - [chapterIndex] 为出错章节索引，越界时取最后一章（Legado
  ///   toc.getOrElse(dur) { toc.last() }）；[verifyContent] 关闭时仅验目录；
  /// - [concurrency] 候选并发上限（Legado AppConfig.threadCount，默认 16）。
  Future<AutoSwitchResult?> execute({
    required String bookId,
    required String currentSourceId,
    String? currentDetailUrl,
    required List<SourceOption> alternatives,
    Map<String, String> variables = const {},
    int chapterIndex = 0,
    int concurrency = 16,
    bool verifyContent = true,
  }) async {
    // 候选过滤：每源一次、跳过当前源/空标识/无详情页/同详情页
    final candidates = <SourceOption>[];
    final attempted = <String>{};
    if (currentSourceId.isNotEmpty) attempted.add(currentSourceId);
    for (final alt in alternatives) {
      final sourceId = alt.sourceId;
      final detailUrl = alt.detailUrl;
      if (sourceId.isEmpty || attempted.contains(sourceId)) continue;
      if (detailUrl == null || detailUrl.isEmpty) continue;
      // 与当前详情页相同：同一页面必然同样失败，跳过
      if (currentDetailUrl != null &&
          currentDetailUrl.isNotEmpty &&
          detailUrl == currentDetailUrl) {
        continue;
      }
      attempted.add(sourceId);
      candidates.add(alt);
    }
    if (candidates.isEmpty) return null;

    // 并发池：同一时刻最多 concurrency 个候选在校验；首个成功者胜出，
    // 其余候选继续跑完但结果被忽略（无便捷取消，代价可接受）。
    final completer = Completer<AutoSwitchResult?>();
    var next = 0;
    var finished = 0;
    Future<void> worker() async {
      while (!completer.isCompleted) {
        final i = next;
        if (i >= candidates.length) return;
        next++;
        try {
          final result = await _validateCandidate(
            alt: candidates[i],
            bookId: bookId,
            variables: variables,
            chapterIndex: chapterIndex,
            verifyContent: verifyContent,
          );
          if (result != null && !completer.isCompleted) {
            completer.complete(result);
          }
        } catch (_) {
          // 单源失败立即弃，不重试（Legado mapParallelSafe 吞错继续）
        }
        finished++;
        if (finished >= candidates.length && !completer.isCompleted) {
          completer.complete(null);
        }
      }
    }

    final workerCount = concurrency < 1 ? 1 : concurrency;
    for (var i = 0; i < workerCount && i < candidates.length; i++) {
      unawaited(worker());
    }
    return completer.future;
  }

  /// 单候选校验：目录非空 + 当前章正文可取（Legado preciseSearch → 详情 →
  /// 目录 → getContentAwait 验证链的等价实现——候选已带详情页，故从目录
  /// 开始；正文验证失败/瞬时异常都使该候选不可用）。
  Future<AutoSwitchResult?> _validateCandidate({
    required SourceOption alt,
    required String bookId,
    required Map<String, String> variables,
    required int chapterIndex,
    required bool verifyContent,
  }) async {
    final detailUrl = alt.detailUrl!;
    final catalog = await repository.getCatalog(
      bookId: bookId,
      sourceId: alt.sourceId,
      detailUrl: detailUrl,
      variables: variables,
    );
    if (catalog.chapters.isEmpty) return null; // 空目录视为不可用
    if (verifyContent) {
      // 当前章索引越界时取最后一章（Legado toc.getOrElse(dur){toc.last()}）
      final chapters = catalog.chapters;
      var index = chapterIndex;
      if (index < 0) index = 0;
      if (index >= chapters.length) index = chapters.length - 1;
      await repository.getChapter(
        bookId: bookId,
        chapterIndex: index,
        sourceId: alt.sourceId,
        detailUrl: detailUrl,
        variables: variables,
      );
    }
    return AutoSwitchResult(
      sourceId: alt.sourceId,
      sourceName: alt.sourceName,
      detailUrl: detailUrl,
      catalog: catalog,
    );
  }
}

/// 自动换源设置：独立 Hive 盒持久化，enabled 默认开启。
/// 阅读页与设置页共用，避免重复定义存储逻辑。
class AutoSwitchSetting {
  static const String boxName = 'auto_switch_setting';
  static const String key = 'enabled';

  static Future<bool> load() async {
    final box = await Hive.openBox<dynamic>(boxName);
    return box.get(key, defaultValue: true) ?? true;
  }

  static Future<void> save(bool enabled) async {
    final box = await Hive.openBox<dynamic>(boxName);
    await box.put(key, enabled);
  }
}
