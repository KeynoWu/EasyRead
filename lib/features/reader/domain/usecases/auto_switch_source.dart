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

/// 自动换源用例：当前书源加载失败时，按序尝试替代书源，
/// 首个能成功拉取目录的源即为可用源；全部失败返回 null。
class AutoSwitchSource {
  final ReaderRepository repository;

  const AutoSwitchSource({required this.repository});

  /// 依次尝试替代书源：
  /// - 跳过当前书源、空标识、无详情页以及与当前详情页相同的源；
  /// - 单个源失败立即尝试下一个（不重试）；
  /// - 空目录视为不可用；
  /// - 返回首个成功源的 {sourceId, sourceName, detailUrl, catalog}，全部失败返回 null。
  Future<AutoSwitchResult?> execute({
    required String bookId,
    required String currentSourceId,
    String? currentDetailUrl,
    required List<SourceOption> alternatives,
    Map<String, String> variables = const {},
  }) async {
    // 已尝试（含当前源）的 sourceId 集合：保证每个源最多尝试一次
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
      try {
        final catalog = await repository.getCatalog(
          bookId: bookId,
          sourceId: sourceId,
          detailUrl: detailUrl,
          variables: variables,
        );
        if (catalog.chapters.isEmpty) continue; // 空目录视为不可用
        return AutoSwitchResult(
          sourceId: sourceId,
          sourceName: alt.sourceName,
          detailUrl: detailUrl,
          catalog: catalog,
        );
      } catch (_) {
        // 单源失败立即尝试下一个，不重试
      }
    }
    return null;
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
