import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/source_subscription.dart';

@HiveType(typeId: 4)
class SourceSubscriptionModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String url;

  @HiveField(3)
  final DateTime? lastUpdatedAt;

  @HiveField(4)
  final String? lastUpdateResult;

  SourceSubscriptionModel({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdatedAt,
    this.lastUpdateResult,
  });

  factory SourceSubscriptionModel.fromEntity(SourceSubscription entity) {
    return SourceSubscriptionModel(
      id: entity.id,
      name: entity.name,
      url: entity.url,
      lastUpdatedAt: entity.lastUpdatedAt,
      lastUpdateResult: entity.lastUpdateResult,
    );
  }

  SourceSubscription toEntity() {
    return SourceSubscription(
      id: id,
      name: name,
      url: url,
      lastUpdatedAt: lastUpdatedAt,
      lastUpdateResult: lastUpdateResult,
    );
  }
}

/// Manual TypeAdapter for SourceSubscriptionModel (typeId: 4)
class SourceSubscriptionModelAdapter extends TypeAdapter<SourceSubscriptionModel> {
  @override
  final int typeId = 4;

  /// 新格式版本魔数：与旧版位置式格式的首字节（id 长度 uint32 高位，恒为 0x00）永不冲突
  static const int _formatMarker = 0x7F;

  @override
  SourceSubscriptionModel read(BinaryReader reader) {
    final first = reader.readByte();
    if (first == _formatMarker) {
      // 新版字段式格式（raw 编码 + 字段键）：未知字段跳过、损坏字段降级默认值
      final numFields = reader.readByte();
      String id = '', name = '', url = '';
      DateTime? lastUpdatedAt;
      String? lastUpdateResult;
      for (int i = 0; i < numFields; i++) {
        final key = reader.readByte();
        switch (key) {
          case 0:
            id = reader.readString();
            break;
          case 1:
            name = reader.readString();
            break;
          case 2:
            url = reader.readString();
            break;
          case 3:
            lastUpdatedAt = reader.readBool()
                ? DateTime.fromMillisecondsSinceEpoch(reader.readInt())
                : null;
            break;
          case 4:
            lastUpdateResult = reader.readBool() ? reader.readString() : null;
            break;
          default:
            // 未知字段键（未来扩展字段）：用类型化 read 消费其值并丢弃，
            // 避免后续字段解析错位（read 按类型标记读取，任意类型均可跳过）
            reader.read();
            break;
        }
      }
      return SourceSubscriptionModel(
        id: id,
        name: name,
        url: url,
        lastUpdatedAt: lastUpdatedAt,
        lastUpdateResult: lastUpdateResult,
      );
    }

    // 旧版位置式格式（raw 编码，无类型标记）：首字节是 id 长度 uint32 的低位字节（Hive 小端）
    final idLength = first |
        (reader.readByte() << 8) |
        (reader.readByte() << 16) |
        (reader.readByte() << 24);
    final id = utf8.decode(reader.readByteList(idLength));
    final name = reader.readString();
    final url = reader.readString();
    final lastUpdatedAt = reader.readBool()
        ? DateTime.fromMillisecondsSinceEpoch(reader.readInt())
        : null;
    final lastUpdateResult =
        reader.readBool() ? reader.readString() : null;
    return SourceSubscriptionModel(
      id: id,
      name: name,
      url: url,
      lastUpdatedAt: lastUpdatedAt,
      lastUpdateResult: lastUpdateResult,
    );
  }

  @override
  void write(BinaryWriter writer, SourceSubscriptionModel obj) {
    writer.writeByte(_formatMarker);
    writer.writeByte(5); // 字段数
    writer.writeByte(0);
    writer.writeString(obj.id);
    writer.writeByte(1);
    writer.writeString(obj.name);
    writer.writeByte(2);
    writer.writeString(obj.url);
    writer.writeByte(3);
    writer.writeBool(obj.lastUpdatedAt != null);
    if (obj.lastUpdatedAt != null) {
      writer.writeInt(obj.lastUpdatedAt!.millisecondsSinceEpoch);
    }
    writer.writeByte(4);
    writer.writeBool(obj.lastUpdateResult != null);
    if (obj.lastUpdateResult != null) {
      writer.writeString(obj.lastUpdateResult!);
    }
  }
}
