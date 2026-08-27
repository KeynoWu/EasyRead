import 'package:hive/hive.dart';
import '../../domain/entities/reading_progress.dart';

@HiveType(typeId: 3)
class ReadingProgressModel extends HiveObject {
  @HiveField(0)
  final String bookId;

  @HiveField(1)
  final int chapterIndex;

  @HiveField(2)
  final int paragraphOffset;

  @HiveField(3)
  final double scrollOffset;

  @HiveField(4)
  final int pageIndex;

  @HiveField(5)
  final DateTime updatedAt;
  @HiveField(6)
  final String? sourceId;

  ReadingProgressModel({
    required this.bookId,
    this.chapterIndex = 0,
    this.paragraphOffset = 0,
    this.scrollOffset = 0.0,
    this.pageIndex = 0,
    required this.updatedAt,
    this.sourceId,
  });

  factory ReadingProgressModel.fromEntity(ReadingProgress entity) {
    return ReadingProgressModel(
      bookId: entity.bookId,
      chapterIndex: entity.chapterIndex,
      paragraphOffset: entity.paragraphOffset,
      scrollOffset: entity.scrollOffset,
      pageIndex: entity.pageIndex,
      updatedAt: entity.updatedAt,
      sourceId: entity.sourceId,
    );
  }

  ReadingProgress toEntity() {
    return ReadingProgress(
      bookId: bookId,
      chapterIndex: chapterIndex,
      paragraphOffset: paragraphOffset,
      scrollOffset: scrollOffset,
      pageIndex: pageIndex,
      updatedAt: updatedAt,
      sourceId: sourceId,
    );
  }
}

/// Manual TypeAdapter for ReadingProgressModel (typeId: 3)
class ReadingProgressModelAdapter extends TypeAdapter<ReadingProgressModel> {
  @override
  final int typeId = 3;

  @override
  ReadingProgressModel read(BinaryReader reader) {
    String? sourceId;
    final model = ReadingProgressModel(
      bookId: reader.readString(),
      chapterIndex: reader.readInt(),
      paragraphOffset: reader.readInt(),
      scrollOffset: reader.readDouble(),
      pageIndex: reader.readInt(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(reader.readInt()),
    );
    // schema 版本标记：旧数据无该字节则跳过，向后兼容。
    if (reader.availableBytes > 0) {
      final version = reader.readInt();
      if (version >= kProgressSchemaVersion) {
        sourceId = reader.readString();
      }
    }
    return ReadingProgressModel(
      bookId: model.bookId,
      chapterIndex: model.chapterIndex,
      paragraphOffset: model.paragraphOffset,
      scrollOffset: model.scrollOffset,
      pageIndex: model.pageIndex,
      updatedAt: model.updatedAt,
      // write 侧 null 以 '' 落盘：读回归一化为 null，保持「null=不追踪源」语义
      sourceId: (sourceId == null || sourceId.isEmpty) ? null : sourceId,
    );
  }

  @override
  void write(BinaryWriter writer, ReadingProgressModel obj) {
    writer.writeString(obj.bookId);
    writer.writeInt(obj.chapterIndex);
    writer.writeInt(obj.paragraphOffset);
    writer.writeDouble(obj.scrollOffset);
    writer.writeInt(obj.pageIndex);
    writer.writeInt(obj.updatedAt.millisecondsSinceEpoch);
    // schema 版本：v2 起在版本字节后追加 sourceId
    writer.writeInt(kProgressSchemaVersion);
    if (kProgressSchemaVersion >= 2) {
      writer.writeString(obj.sourceId ?? '');
    }
  }
}

/// ReadingProgressModelAdapter 写入的 schema 版本。
const int kProgressSchemaVersion = 2;
