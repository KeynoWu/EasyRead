import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive/hive.dart';
import 'book_detail_service.dart';
import '../../../reader/domain/repositories/reader_repository.dart';
import '../../domain/entities/book.dart';
import '../../domain/repositories/bookshelf_repository.dart';

/// 自动更新书架设置：0 表示关闭，正数表示间隔小时数。
class AutoRefreshSettings {
  static const String boxName = 'auto_refresh';
  static const String key = 'intervalHours';

  static Future<int> load() async {
    final box = await Hive.openBox<int>(boxName);
    return box.get(key, defaultValue: 0) ?? 0;
  }

  static Future<void> save(int hours) async {
    final box = await Hive.openBox<int>(boxName);
    await box.put(key, hours);
  }
}

/// 后台更新全部书架书籍详情，失败的单本不中断整批。
class BookshelfAutoUpdater {
  final ReaderRepository readerRepo;
  final BookshelfRepository bookshelfRepo;
  final BookDetailService detailService;

  const BookshelfAutoUpdater({
    required this.readerRepo,
    required this.bookshelfRepo,
    required this.detailService,
  });

  Future<int> updateAll() async {
    var updated = 0;
    for (final book in await bookshelfRepo.getAll()) {
      final sourceId = book.sourceId;
      if (sourceId == null) continue;
      final detail = await detailService.get(book.id);
      final detailUrl = detail?.detailUrl;
      if (detailUrl == null || detailUrl.isEmpty) continue;
      try {
        final fetched = await readerRepo.getBookDetail(
          bookId: book.id,
          sourceId: sourceId,
          detailUrl: detailUrl,
          variables: BookDetail.decodeVariables(detail?.variablesJson),
        );
        await bookshelfRepo.save(Book(
          id: book.id,
          name: fetched.name ?? book.name,
          author: fetched.author ?? book.author,
          coverUrl: fetched.coverUrl ?? book.coverUrl,
          sourceId: sourceId,
          lastChapter: fetched.lastChapter ?? book.lastChapter,
          progress: book.progress,
          group: book.group,
          lastReadAt: book.lastReadAt,
        ));
        updated++;
      } catch (_) {
        // 单本更新失败不中断自动任务
      }
    }
    return updated;
  }
}

/// 应用存活期间的定时调度器；设置变化时调用 [restart] 重建定时器。
class AutoRefreshScheduler {
  static Timer? _timer;

  static Future<void> restart(Future<int> Function() update) async {
    _timer?.cancel();
    _timer = null;
    final hours = await AutoRefreshSettings.load();
    if (hours <= 0) return;
    _timer = Timer.periodic(Duration(hours: hours), (_) => update());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @visibleForTesting
  static bool get isRunning => _timer != null;
}
