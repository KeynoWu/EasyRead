import 'dart:convert';
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../../../features/book_source/domain/entities/book_source.dart';
import '../../../../features/book_source/domain/repositories/book_source_repository.dart';
import '../../../../features/search/data/engines/rule_engine.dart';
import '../../domain/entities/chapter.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/entities/reading_progress.dart';
import '../../domain/repositories/reader_repository.dart';
import '../models/chapter_model.dart';
import '../models/reading_progress_model.dart';

/// 章节加载失败时抛出的业务异常，由 UI 转成可重试的错误态。
class ChapterLoadException implements Exception {
  final String message;

  const ChapterLoadException(this.message);

  @override
  String toString() => message;
}

class ReaderRepositoryImpl implements ReaderRepository {
  final DioClient _client;
  PurifyPipeline _pipeline;
  final BookSourceRepository _sourceRepo;
  Box<ChapterModel>? _cachedChapterBox;
  Box<ReadingProgressModel>? _cachedProgressBox;
  ChapterCatalog? _cachedCatalog;
  String? _cachedCatalogKey;

  Future<Box<ChapterModel>> _chapterBox() async =>
      _cachedChapterBox ??= await Hive.openBox<ChapterModel>(HiveBoxes.chapters);

  Future<Box<ReadingProgressModel>> _progressBox() async =>
      _cachedProgressBox ??= await Hive.openBox<ReadingProgressModel>(HiveBoxes.readingProgress);

  ReaderRepositoryImpl({
    DioClient? client,
    PurifyPipeline? pipeline,
    BookSourceRepository? sourceRepo,
  })  : _client = client ?? DioClient(),
        _pipeline = pipeline ?? PurifyPipeline(),
        _sourceRepo = sourceRepo ?? _EmptySourceRepo();

  /// 运行时注入净化规则（用户配置加载完成后调用）
  void setPipeline(PurifyPipeline pipeline) {
    _pipeline = pipeline;
  }

  Future<BookSource?> _getSource(String sourceId) async {
    return _sourceRepo.getById(sourceId);
  }

  @override
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
  }) async {
    final source = await _getSource(sourceId);
    if (source == null || detailUrl.isEmpty || source.chapterListRule == null) {
      return ChapterCatalog(bookId: bookId, fetchedAt: DateTime.now());
    }

    final cacheKey =
        '${bookId}_${sourceId}_$detailUrl|${source.chapterListRule}|${source.chapterNameRule}|${source.chapterUrlRule}|${jsonEncode(source.requestHeaders)}';
    if (_cachedCatalogKey == cacheKey && _cachedCatalog != null) {
      return _cachedCatalog!;
    }

    try {
      final headers = source.requestHeaders;
      final html = await _client.getString(
        detailUrl,
        headers: headers.isEmpty ? null : headers,
        sourceId: sourceId,
      );
      final items = RuleEngine.extractElements(html, source.chapterListRule);
      final chapters = <ChapterItem>[];

      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item == null) continue;
        final title = RuleEngine.getElementText(item, source.chapterNameRule);
        final url = RuleEngine.getElementText(item, source.chapterUrlRule);
        if (title == null || title.isEmpty) continue;
        chapters.add(ChapterItem(
          title: title,
          url: url ?? '',
          index: i,
        ));
      }

      final catalog = ChapterCatalog(bookId: bookId, chapters: chapters, fetchedAt: DateTime.now());
      if (catalog.chapters.isNotEmpty) {
        _cachedCatalog = catalog;
        _cachedCatalogKey = cacheKey;
      }
      return catalog;
    } catch (_) {
      return ChapterCatalog(bookId: bookId, fetchedAt: DateTime.now());
    }
  }

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
  }) async {
    // 先检查缓存（key 含 sourceId，避免换源后读到其他书源的内容）
    final cacheBox = await _chapterBox();
    final cacheKey = '${bookId}_${sourceId}_$chapterIndex';
    final cached = cacheBox.get(cacheKey);
    if (cached != null) {
      return cached.toEntity();
    }

    final source = await _getSource(sourceId);
    if (source == null || source.contentUrl == null) {
      throw const ChapterLoadException('书源不可用或未配置内容规则');
    }

    try {
      // 获取目录以确定章节 URL 与真实标题
      var chapterUrl = '';
      var chapterTitle = '';
      if (detailUrl != null && detailUrl.isNotEmpty) {
        final catalog = await getCatalog(
          bookId: bookId,
          sourceId: sourceId,
          detailUrl: detailUrl,
        );
        if (chapterIndex < catalog.chapters.length) {
          chapterUrl = catalog.chapters[chapterIndex].url;
          chapterTitle = catalog.chapters[chapterIndex].title;
        }
      }

      if (chapterUrl.isEmpty) {
        throw const ChapterLoadException('无法定位章节');
      }

      // 拉取章节内容
      final contentUrl = _buildContentUrl(source.contentUrl!, chapterUrl, chapterIndex);
      final headers = source.requestHeaders;
      final html = await _client.getString(
        contentUrl,
        headers: headers.isEmpty ? null : headers,
        sourceId: sourceId,
      );

      // 提取正文
      var content = '';
      if (source.chapterContentRule != null) {
        content = RuleEngine.extractText(html, source.chapterContentRule) ?? '';
      }
      if (content.isEmpty) {
        // 兜底：取净化后的全文
        content = _pipeline.purify(html);
      }

      if (content.trim().isEmpty) {
        throw const ChapterLoadException('章节内容为空');
      }

      final title = chapterTitle.isEmpty ? '第${chapterIndex + 1}章' : chapterTitle;
      final chapter = Chapter(
        id: cacheKey,
        bookId: bookId,
        title: title,
        content: content,
        index: chapterIndex,
        sourceId: sourceId,
        cachedAt: DateTime.now(),
      );

      await cacheBox.put(cacheKey, ChapterModel.fromEntity(chapter));
      await _trimCache(cacheBox);
      return chapter;
    } catch (_) {
      throw const ChapterLoadException('章节加载失败，请检查网络或书源规则');
    }
  }

  /// 构建内容 URL：支持 {{id}} 和直接 URL 两种方式
  String _buildContentUrl(String template, String chapterUrl, int index) {
    if (chapterUrl.startsWith('http')) {
      return chapterUrl;
    }
    return template
        .replaceAll('{{id}}', chapterUrl)
        .replaceAll('{{index}}', '$index');
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    final box = await _progressBox();
    await box.put(progress.bookId, ReadingProgressModel.fromEntity(progress));
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async {
    final box = await _progressBox();
    final model = box.get(bookId);
    return model?.toEntity();
  }

  @override
  Future<void> clearBookCache(String bookId) async {
    final box = await _chapterBox();
    final keys = box.keys.where((k) => (k as String).startsWith('${bookId}_'));
    await box.deleteAll(keys);
  }

  @override
  Future<void> preloadChapters({
    required String bookId,
    required int startIndex,
    required int count,
    required String sourceId,
    String? detailUrl,
  }) async {
    for (int i = 0; i < count; i++) {
      final index = startIndex + i;
      try {
        await getChapter(
          bookId: bookId,
          chapterIndex: index,
          sourceId: sourceId,
          detailUrl: detailUrl,
        );
      } catch (_) {
        // 预加载失败不阻塞当前阅读
      }
    }
  }

  /// 缓存上限控制：超过 [maxEntries] 时淘汰最旧的章节
  static const int maxEntries = 500;

  Future<void> _trimCache(Box<ChapterModel> box) async {
    if (box.length <= maxEntries) return;
    final entries = box.values.toList()
      ..sort((a, b) {
        final at = a.cachedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.cachedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return at.compareTo(bt);
      });
    final toRemove = entries.take(entries.length - maxEntries).map((e) => e.key);
    await box.deleteAll(toRemove);
  }
}

/// 空书源仓库（无依赖注入时使用）
class _EmptySourceRepo implements BookSourceRepository {
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
