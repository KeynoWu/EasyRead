import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import '../../domain/entities/chapter_catalog.dart';
import '../../domain/repositories/reader_repository.dart';

/// 整本缓存盒：BookCacheService 写入、BookExporter 读取共用。
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
  Future<BookCacheResult> cacheBook({
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
    return BookCacheResult(
      total: total,
      cached: cached,
      hit: hit,
      failed: failed,
      cancelled: cancelToken != null && cancelToken.isCancelled,
    );
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
