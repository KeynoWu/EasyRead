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

  ReadingProgressModel({
    required this.bookId,
    this.chapterIndex = 0,
    this.paragraphOffset = 0,
    this.scrollOffset = 0.0,
    this.pageIndex = 0,
    required this.updatedAt,
  });

  factory ReadingProgressModel.fromEntity(ReadingProgress entity) {
    return ReadingProgressModel(
      bookId: entity.bookId,
      chapterIndex: entity.chapterIndex,
      paragraphOffset: entity.paragraphOffset,
      scrollOffset: entity.scrollOffset,
      pageIndex: entity.pageIndex,
      updatedAt: entity.updatedAt,
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
    );
  }
}

/// Manual TypeAdapter for ReadingProgressModel (typeId: 3)
class ReadingProgressModelAdapter extends TypeAdapter<ReadingProgressModel> {
  @override
  final int typeId = 3;

  @override
  ReadingProgressModel read(BinaryReader reader) {
    return ReadingProgressModel(
      bookId: reader.readString(),
      chapterIndex: reader.readInt(),
      paragraphOffset: reader.readInt(),
      scrollOffset: reader.readDouble(),
      pageIndex: reader.readInt(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(reader.readInt()),
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
  }
}
