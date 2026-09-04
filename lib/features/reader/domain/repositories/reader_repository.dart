import '../../../settings/domain/entities/chinese_conversion.dart';
import '../entities/chapter.dart';
import '../entities/chapter_catalog.dart';
import '../entities/book_detail.dart';
import '../entities/reading_progress.dart';

/// 阅读器仓库接口
abstract class ReaderRepository {
  /// 获取章节目录（优先缓存，无缓存时从网络获取）
  Future<ChapterCatalog> getCatalog({
    required String bookId,
    required String sourceId,
    required String detailUrl,
    Map<String, String> variables = const {},
  });

  /// 获取书籍详情摘要（含简介/作者/封面/最新章节等）。
  Future<BookDetail> getBookDetail({
    required String bookId,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
  });

  /// 获取章节内容（优先缓存，无缓存时从网络获取）。
  /// [chineseMode]：简繁转换在用户净化规则前套用（Legado ContentProcessor
  /// getContent 顺序：chineseConvert → 替换规则），繁体站配简体净化规则可命中。
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
    String? detailUrl,
    Map<String, String> variables = const {},
    ChineseConversionMode chineseMode = ChineseConversionMode.original,
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
    String? detailUrl,
    Map<String, String> variables = const {},
  });
}
