import 'package:hive/hive.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../domain/entities/chapter.dart';
import '../../domain/entities/reading_progress.dart';
import '../../domain/repositories/reader_repository.dart';
import '../models/chapter_model.dart';
import '../models/reading_progress_model.dart';

class ReaderRepositoryImpl implements ReaderRepository {
  final DioClient _client;
  final PurifyPipeline _pipeline;

  ReaderRepositoryImpl({DioClient? client, PurifyPipeline? pipeline})
      : _client = client ?? DioClient(),
        _pipeline = pipeline ?? PurifyPipeline();

  @override
  Future<Chapter> getChapter({
    required String bookId,
    required int chapterIndex,
    required String sourceId,
  }) async {
    // 先检查缓存
    final cacheBox = await Hive.openBox<ChapterModel>('chapters');
    final cacheKey = '${bookId}_$chapterIndex';
    final cached = cacheBox.get(cacheKey);
    if (cached != null) {
      return cached.toEntity();
    }

    // Phase 2 简化：返回占位内容
    // 完整实现需在 Phase 2 后期接入书源规则
    final chapter = Chapter(
      id: cacheKey,
      bookId: bookId,
      title: '第${chapterIndex + 1}章',
      content: '章节内容加载中...',
      index: chapterIndex,
      sourceId: sourceId,
      cachedAt: DateTime.now(),
    );

    // 写入缓存
    await cacheBox.put(cacheKey, ChapterModel.fromEntity(chapter));
    return chapter;
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    final box = await Hive.openBox<ReadingProgressModel>('reading_progress');
    await box.put(progress.bookId, ReadingProgressModel.fromEntity(progress));
  }

  @override
  Future<ReadingProgress?> loadProgress(String bookId) async {
    final box = await Hive.openBox<ReadingProgressModel>('reading_progress');
    final model = box.get(bookId);
    return model?.toEntity();
  }

  @override
  Future<void> clearBookCache(String bookId) async {
    final box = await Hive.openBox<ChapterModel>('chapters');
    final keys = box.keys.where((k) => (k as String).startsWith('${bookId}_'));
    await box.deleteAll(keys);
  }

  @override
  Future<void> preloadChapters({
    required String bookId,
    required int startIndex,
    required int count,
    required String sourceId,
  }) async {
    for (int i = 0; i < count; i++) {
      final index = startIndex + i;
      // 只预加载缓存中不存在的章节
      await getChapter(
        bookId: bookId,
        chapterIndex: index,
        sourceId: sourceId,
      );
    }
  }
}
