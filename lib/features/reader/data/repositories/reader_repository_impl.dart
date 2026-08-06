import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive/hive.dart';
import '../../../../core/database/hive_init.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
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
    } catch (e) {
      // 目录加载失败（网络/解析）：抛错而非静默返空目录，
      // 避免上层误判"无章节"进而级联成无关的章节加载失败。
      throw const ChapterLoadException('目录加载失败');
    }
  }

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
  }) async {
    // 先检查缓存（key 含 sourceId，避免换源后读到其他书源的内容；
    // v3 版本前缀：正文 URL 选择逻辑变更后强制旧缓存失效）
    final cacheBox = await _chapterBox();
    final cacheKey = 'v3_${bookId}_${sourceId}_$chapterIndex';
    final cached = cacheBox.get(cacheKey);
    if (cached != null) {
      return cached.toEntity();
    }

    final source = await _getSource(sourceId);
    if (source == null) {
      throw const ChapterLoadException('书源不可用或未配置内容规则');
    }

    try {
      // 获取目录以确定章节 URL 与真实标题。目录加载失败不阻断正文：
      // 退化为正文 URL 模板 / detailUrl 兜底定位正文页。
      var chapterUrl = '';
      var chapterTitle = '';
      if (detailUrl != null && detailUrl.isNotEmpty) {
        try {
          final catalog = await getCatalog(
            bookId: bookId,
            sourceId: sourceId,
            detailUrl: detailUrl,
          );
          if (chapterIndex < catalog.chapters.length) {
            chapterUrl = catalog.chapters[chapterIndex].url;
            chapterTitle = catalog.chapters[chapterIndex].title;
          }
        } on ChapterLoadException {
          // 目录加载失败：留空 chapterUrl，靠正文 URL 选择兜底
        }
      }

      // 正文页 URL 选择（Legado 语义）：
      // 1. contentUrl 模板 + 章节 URL
      // 2. contentUrl 为空时 → 目录提取的章节 URL（章节页才是正文页；
      //    相对路径基于详情页 resolve）
      // 3. 目录为空（无 chapterUrl 规则）→ 详情页兜底
      String contentUrl;
      if (source.contentUrl != null && source.contentUrl!.isNotEmpty) {
        contentUrl = _buildContentUrl(source.contentUrl!, chapterUrl, chapterIndex);
      } else if (chapterUrl.isNotEmpty) {
        if (chapterUrl.startsWith('http')) {
          contentUrl = chapterUrl;
        } else if (detailUrl != null && detailUrl.isNotEmpty) {
          contentUrl = Uri.parse(detailUrl).resolve(chapterUrl).toString();
        } else {
          // 相对章节 URL 且无详情页可 resolve：无法定位正文页
          throw const ChapterLoadException('无法定位章节');
        }
      } else if (detailUrl != null && detailUrl.isNotEmpty) {
        contentUrl = detailUrl;
      } else {
        throw const ChapterLoadException('无法定位章节');
      }
      debugPrint('[reader] contentUrl=$contentUrl chapterUrl=$chapterUrl detail=$detailUrl');
      final headers = source.requestHeaders;
      final html = await _client.getString(
        contentUrl,
        headers: headers.isEmpty ? null : headers,
        sourceId: sourceId,
      );
      debugPrint('[reader] html len=${html.length}');

      // 提取正文
      var content = '';
      if (source.chapterContentRule != null) {
        content = RuleEngine.extractText(html, source.chapterContentRule) ?? '';
        debugPrint('[reader] extractText=${source.chapterContentRule} -> ${content.length}');
      }
      if (content.isEmpty) {
        // 兜底一：智能提取页面正文主体（规则失配/缺失时，跳过导航与杂项）
        content = _extractMainText(html);
        debugPrint('[reader] mainText fallback -> ${content.length}');
      }
      if (content.isEmpty) {
        // 兜底二：整页净化（含 quickjs JS 规则；iOS 无引擎时跳过 JS 规则）
        content = await _pipeline.purifyAsync(html);
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
    } on ChapterLoadException {
      // 已含明确语义的错误（书源不可用/无法定位/内容为空）直接透传，
      // 不被兜底文案覆盖，便于用户定位问题。
      rethrow;
    } catch (_) {
      throw const ChapterLoadException('章节加载失败，请检查网络或书源规则');
    }
  }

  /// 非可见/非正文标签：其文本不应作为正文主体候选（脚本/样式文本可能
  /// 比真正的正文容器还长，会反向选中并作为"正文"返回）。
  /// 注意：跳过的不仅是直接命中的标签本身，还要跳过其整棵子树——
  /// 正文容器内可能嵌套 script/style，Element.text 会包含其文本。
  static const Set<String> _nonContentTags = {
    'script', 'style', 'noscript', 'template',
    'svg', 'iframe', 'nav', 'header', 'footer', 'aside',
  };

  /// 元素的可见文本：DFS 收集文本节点，遇到 [_nonContentTags] 直接跳过
  /// 整棵子树。与 `Element.text` 的区别在于排除嵌套的脚本/样式文本，
  /// 防止"正文容器内嵌长 script"导致脚本文本被当作正文候选。
  static String _visibleText(dom.Element element) {
    final buffer = StringBuffer();
    final stack = <dom.Node>[element];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node is dom.Text) {
        buffer.write(node.text);
      } else if (node is dom.Element) {
        if (_nonContentTags.contains(node.localName)) continue;
        for (final child in node.nodes.reversed) {
          stack.add(child);
        }
      }
    }
    return buffer.toString();
  }

  /// 智能正文提取：正文规则失配/缺失时，从页面中找出文本最多的深层
  /// 容器作为正文（跳过导航/推荐/评论等杂项）。规则提取失败时兜底，
  /// 内容质量优于整页净化。
  static String _extractMainText(String html) {
    try {
      final doc = parser.parse(html);
      final body = doc.body;
      if (body == null) return '';
      var best = '';
      final stack = <dom.Element>[body];
      while (stack.isNotEmpty) {
        final el = stack.removeLast();
        for (final child in el.children) {
          if (_nonContentTags.contains(child.localName)) continue;
          final text = _visibleText(child).trim();
          if (text.length >= 200 && text.length > best.length) {
            best = text;
          }
          stack.add(child);
        }
      }
      return best;
    } catch (_) {
      return '';
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
    final keys = box.keys
        .where((k) => (k as String).startsWith('v3_${bookId}_'));
    await box.deleteAll(keys);
    // 同步失效同书的内存目录缓存：避免换源/清缓存后旧目录残留，
    // 也避免下次目录加载失败时误用上一本书的目录。
    if (_cachedCatalogKey != null &&
        _cachedCatalogKey!.startsWith('${bookId}_')) {
      _cachedCatalog = null;
      _cachedCatalogKey = null;
    }
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
