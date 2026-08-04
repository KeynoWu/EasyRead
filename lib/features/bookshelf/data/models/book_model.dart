import 'package:hive/hive.dart';
import '../../domain/entities/book.dart';

/// Hive 可存储的书籍数据模型
///
/// 手动实现 TypeAdapter，避免 hive_generator 兼容性问题。
/// 注意：Hive 2.2.3 的 readString() 返回非空 String 且不处理 null，
///       因此 nullable 字段使用 readBool() 标志位 + readString() 实现。
class BookModel extends HiveObject {
  final String id;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? sourceId;
  final String? lastChapter;
  final double progress;
  final DateTime lastReadAt;

  BookModel({
    required this.id,
    required this.name,
    this.author,
    this.coverUrl,
    this.sourceId,
    this.lastChapter,
    this.progress = 0.0,
    required this.lastReadAt,
  });

  factory BookModel.fromEntity(Book book) {
    return BookModel(
      id: book.id,
      name: book.name,
      author: book.author,
      coverUrl: book.coverUrl,
      sourceId: book.sourceId,
      lastChapter: book.lastChapter,
      progress: book.progress,
      lastReadAt: book.lastReadAt,
    );
  }

  Book toEntity() {
    return Book(
      id: id,
      name: name,
      author: author,
      coverUrl: coverUrl,
      sourceId: sourceId,
      lastChapter: lastChapter,
      progress: progress,
      lastReadAt: lastReadAt,
    );
  }
}

/// 手动实现的 Hive TypeAdapter
class BookModelAdapter extends TypeAdapter<BookModel> {
  @override
  final int typeId = 0;

  @override
  BookModel read(BinaryReader reader) {
    return BookModel(
      id: reader.readString(),
      name: reader.readString(),
      author: reader.readBool() ? reader.readString() : null,
      coverUrl: reader.readBool() ? reader.readString() : null,
      sourceId: reader.readBool() ? reader.readString() : null,
      lastChapter: reader.readBool() ? reader.readString() : null,
      progress: reader.readDouble(),
      lastReadAt: DateTime.fromMillisecondsSinceEpoch(reader.readInt()),
    );
  }

  @override
  void write(BinaryWriter writer, BookModel obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.name);
    writer.writeBool(obj.author != null);
    if (obj.author != null) writer.writeString(obj.author!);
    writer.writeBool(obj.coverUrl != null);
    if (obj.coverUrl != null) writer.writeString(obj.coverUrl!);
    writer.writeBool(obj.sourceId != null);
    if (obj.sourceId != null) writer.writeString(obj.sourceId!);
    writer.writeBool(obj.lastChapter != null);
    if (obj.lastChapter != null) writer.writeString(obj.lastChapter!);
    writer.writeDouble(obj.progress);
    writer.writeInt(obj.lastReadAt.millisecondsSinceEpoch);
  }
}
