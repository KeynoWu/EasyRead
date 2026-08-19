import 'package:hive/hive.dart';
import '../../domain/entities/chapter.dart';

@HiveType(typeId: 2)
class ChapterModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String bookId;

  @HiveField(2)
  final String title;

  @HiveField(3)
  final String content;

  @HiveField(4)
  final int index;

  @HiveField(5)
  final String? sourceId;

  @HiveField(6)
  final DateTime? cachedAt;

  ChapterModel({
    required this.id,
    required this.bookId,
    required this.title,
    required this.content,
    required this.index,
    this.sourceId,
    this.cachedAt,
  });

  factory ChapterModel.fromEntity(Chapter chapter) {
    return ChapterModel(
      id: chapter.id,
      bookId: chapter.bookId,
      title: chapter.title,
      content: chapter.content,
      index: chapter.index,
      sourceId: chapter.sourceId,
      cachedAt: chapter.cachedAt,
    );
  }

  Chapter toEntity() {
    return Chapter(
      id: id,
      bookId: bookId,
      title: title,
      content: content,
      index: index,
      sourceId: sourceId,
      cachedAt: cachedAt,
    );
  }
}

/// Manual TypeAdapter for ChapterModel (typeId: 2)
class ChapterModelAdapter extends TypeAdapter<ChapterModel> {
  @override
  final int typeId = 2;

  @override
  ChapterModel read(BinaryReader reader) {
    final model = ChapterModel(
      id: reader.readString(),
      bookId: reader.readString(),
      title: reader.readString(),
      content: reader.readString(),
      index: reader.readInt(),
      sourceId: reader.readBool() ? reader.readString() : null,
      cachedAt: reader.readBool() ? DateTime.fromMillisecondsSinceEpoch(reader.readInt()) : null,
    );
    // schema 版本标记：旧数据无该字节则跳过，向后兼容。
    if (reader.availableBytes > 0) reader.readInt();
    return model;
  }

  @override
  void write(BinaryWriter writer, ChapterModel obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.bookId);
    writer.writeString(obj.title);
    writer.writeString(obj.content);
    writer.writeInt(obj.index);
    writer.writeBool(obj.sourceId != null);
    if (obj.sourceId != null) writer.writeString(obj.sourceId!);
    writer.writeBool(obj.cachedAt != null);
    if (obj.cachedAt != null) writer.writeInt(obj.cachedAt!.millisecondsSinceEpoch);
    writer.writeInt(kChapterSchemaVersion);
  }
}

/// ChapterModelAdapter 写入的 schema 版本。
const int kChapterSchemaVersion = 1;
