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

  @override
  SourceSubscriptionModel read(BinaryReader reader) {
    return SourceSubscriptionModel(
      id: reader.readString(),
      name: reader.readString(),
      url: reader.readString(),
      lastUpdatedAt: reader.readBool() ? DateTime.fromMillisecondsSinceEpoch(reader.readInt()) : null,
      lastUpdateResult: reader.readBool() ? reader.readString() : null,
    );
  }

  @override
  void write(BinaryWriter writer, SourceSubscriptionModel obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.name);
    writer.writeString(obj.url);
    writer.writeBool(obj.lastUpdatedAt != null);
    if (obj.lastUpdatedAt != null) writer.writeInt(obj.lastUpdatedAt!.millisecondsSinceEpoch);
    writer.writeBool(obj.lastUpdateResult != null);
    if (obj.lastUpdateResult != null) writer.writeString(obj.lastUpdateResult!);
  }
}
