import '../entities/chapter.dart';
import '../entities/reading_progress.dart';

/// 阅读器仓库接口
abstract class ReaderRepository {
  /// 获取章节内容（优先缓存，无缓存时从网络获取）
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
  });

  /// 保存阅读进度
  Future<void> saveProgress(ReadingProgress progress);

  /// 加载阅读进度
  Future<ReadingProgress?> loadProgress(String bookId);

  /// 清除书籍的所有缓存章节
  Future<void> clearBookCache(String bookId);

  /// 预加载后续章节到缓存
  Future<void> preloadChapters({
    required String bookId,
    required int startIndex,
    required int count,
    required String sourceId,
  });
}
