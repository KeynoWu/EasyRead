import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/repositories/reader_repository.dart';

/// 整本缓存盒：BookCacheService 写入、阅读器读取共用。
///
/// 盒名 `book_cache`，与阅读器既有的 LRU 章节缓存盒（`chapters`）相互独立：
/// - 章节内容：`bookId|chapterIndex` → 净化后 HTML（String）
/// - 书源元数据：`__meta_$bookId` → {sourceId, updatedAt}（Map）
class BookCacheBox {
  BookCacheBox._();

  static const String boxName = 'book_cache';

  /// 章节内容 key
  static String chapterKey(String bookId, int chapterIndex) =>
      '$bookId|$chapterIndex';

  /// 书源元数据 key
  static String metaKey(String bookId) => '__meta_$bookId';

  /// 打开整本缓存盒（String 章节与 Map 元数据混合存储，使用动态类型盒）
  static Future<Box> open() async => Hive.openBox(boxName);

  /// 读取单章净化 HTML；未缓存返回 null
  static Future<String?> readChapter(String bookId, int chapterIndex) async {
    final box = await open();
    final value = box.get(chapterKey(bookId, chapterIndex));
    return value is String ? value : null;
  }

  /// 读取书源元数据；未缓存返回 null
  static Future<Map<dynamic, dynamic>?> readMeta(String bookId) async {
    final box = await open();
    final value = box.get(metaKey(bookId));
    return value is Map ? Map<dynamic, dynamic>.from(value) : null;
  }
}

/// 整本缓存服务：按目录逐章拉取正文，写入整本缓存盒（断点续传）。
class BookCacheService {
  final ReaderRepository repository;

  BookCacheService({required this.repository});

  /// 整本缓存（book_cache）的上限：最多保留最近缓存的整本书。
  /// 整本缓存用于导出，必须保持单本书内部章节完整，故不做单章淘汰，
  /// 只按元数据 updatedAt 淘汰最久未被重新缓存的整本书（含其章节+meta）。
  static const int maxBooks = 20;

  /// 整本缓存：
  /// - 跳过已缓存章节（命中计数）；失败章节计入 [BookCacheResult.failed]
  ///   并继续，重跑时自动重试；
  /// - [onProgress] 回调 `(done, total, 当前章标题)`；
  /// - [cancelToken] 取消：章节间检查，取消后返回 `cancelled=true`，
  ///   已缓存部分保留；
  /// - 开始即写入 meta（sourceId/updatedAt），中途取消/失败后已缓存
  ///   部分仍可导出。
  ///
  /// [chapters] 为空时按目录从仓库拉取（调用方已有目录时可传入复用，
  /// 避免重复请求）。
  /// 同书同源的并发去重：缓存期间再次触发直接复用同一 Future，
  /// 避免 check-then-act 竞态导致重复拉取或混入不同源章节。
  static final Map<String, Future<BookCacheResult>> _inFlight = {};

  Future<BookCacheResult> cacheBook({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    List<ChapterItem>? chapters,
    Map<String, String> variables = const {},
    void Function(int done, int total, String title)? onProgress,
    CancelToken? cancelToken,
  }) {
    final key = '$bookId|$sourceId';
    final running = _inFlight[key];
    if (running != null) return running;
    final future = _cacheBook(
      bookId: bookId,
      sourceId: sourceId,
      detailUrl: detailUrl,
      chapters: chapters,
      variables: variables,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<BookCacheResult> _cacheBook({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    List<ChapterItem>? chapters,
    Map<String, String> variables = const {},
    void Function(int done, int total, String title)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final List<ChapterItem> items;
    if (chapters != null) {
      items = chapters;
    } else {
      final catalog = await repository.getCatalog(
        bookId: bookId,
        sourceId: sourceId,
        detailUrl: detailUrl,
        variables: variables,
      );
      items = catalog.chapters;
    }
    final total = items.length;
    final box = await BookCacheBox.open();
    // 换源防护：旧 meta 的 sourceId 与本次不同时，清掉该书全部已缓存章节，
    // 避免导出静默混入旧书源内容（章节 key 只有 bookId|chapterIndex，无法区分来源）
    final previous = box.get(BookCacheBox.metaKey(bookId));
    if (previous is Map && previous['sourceId'] != sourceId) {
      final staleKeys = box.keys
          .where((k) => k.toString().startsWith('$bookId|'))
          .toList();
      if (staleKeys.isNotEmpty) {
        await box.deleteAll(staleKeys);
      }
    }
    await box.put(
      BookCacheBox.metaKey(bookId),
      {'sourceId': sourceId, 'updatedAt': DateTime.now()},
    );
    var cached = 0;
    var hit = 0;
    var failed = 0;
    for (var i = 0; i < total; i++) {
      if (cancelToken != null && cancelToken.isCancelled) break;
      final item = items[i];
      if (box.containsKey(BookCacheBox.chapterKey(bookId, item.index))) {
        hit++;
      } else {
        try {
          final chapter = await repository.getChapter(
            bookId: bookId,
            chapterIndex: item.index,
            sourceId: sourceId,
            detailUrl: detailUrl,
            variables: variables,
          );
          await box.put(
            BookCacheBox.chapterKey(bookId, chapter.index),
            chapter.content,
          );
          cached++;
        } catch (_) {
          // 单章失败不中断整本缓存：重跑时自动重试
          failed++;
        }
      }
      onProgress?.call(i + 1, total, item.title);
    }
    if (cancelToken == null || !cancelToken.isCancelled) {
      await _trimCacheBooks(box);
    }
    return BookCacheResult(
      total: total,
      cached: cached,
      hit: hit,
      failed: failed,
      cancelled: cancelToken != null && cancelToken.isCancelled,
    );
  }

  /// 按书数限制淘汰最旧的整本缓存：超过 [maxBooks] 时删除最久未缓存的书
  /// （章节 + 元数据），避免 disk 无界增长。单本书内部不淘汰，保证导出完整。
  Future<void> _trimCacheBooks(Box box) async {
    final metaKeys = box.keys
        .where((k) => k.toString().startsWith('__meta_'))
        .toList();
    if (metaKeys.length <= maxBooks) return;
    final updatedAt = <String, DateTime>{};
    for (final k in metaKeys) {
      final v = box.get(k);
      final ms = v is Map ? v['updatedAt'] : null;
      updatedAt[k.toString()] =
          ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : DateTime.fromMillisecondsSinceEpoch(0);
    }
    final oldest = metaKeys.map((k) => k.toString()).toList()
      ..sort((a, b) => updatedAt[a]!.compareTo(updatedAt[b]!));
    final evictCount = oldest.length - maxBooks;
    final bookIds = [
      for (final metaKey in oldest.take(evictCount))
        metaKey.substring('__meta_'.length),
    ];
    final toDelete = <dynamic>[];
    for (final key in box.keys) {
      final s = key.toString();
      if (bookIds.any((id) => s == '__meta_$id' || s.startsWith('$id|'))) {
        toDelete.add(key);
      }
    }
    if (toDelete.isNotEmpty) {
      await box.deleteAll(toDelete);
    }
  }

  /// 已缓存章节数（断点续传/导出前置判断用）
  Future<int> countCached(String bookId) async {
    final box = await BookCacheBox.open();
    final prefix = '$bookId|';
    return box.keys
        .where((key) => key is String && key.startsWith(prefix))
        .length;
  }

  /// 整本缓存的元数据（未缓存返回 null）
  Future<Map<dynamic, dynamic>?> meta(String bookId) =>
      BookCacheBox.readMeta(bookId);
}

/// 整本缓存结果统计
class BookCacheResult {
  /// 本次处理章节总数
  final int total;

  /// 本次新缓存章节数
  final int cached;

  /// 已缓存跳过（命中）章节数
  final int hit;

  /// 拉取失败章节数
  final int failed;

  /// 是否被取消
  final bool cancelled;

  const BookCacheResult({
    required this.total,
    required this.cached,
    required this.hit,
    required this.failed,
    required this.cancelled,
  });
}
