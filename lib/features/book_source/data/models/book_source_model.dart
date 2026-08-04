import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/book_source.dart';

/// Hive 可存储的书源数据模型
class BookSourceModel extends HiveObject {
  final String id;
  final String name;
  final String? bookSourceUrl;
  final String? bookSourceGroup;
  final bool enabled;
  final String rulesJson;

  BookSourceModel({
    required this.id,
    required this.name,
    this.bookSourceUrl,
    this.bookSourceGroup,
    this.enabled = true,
    required this.rulesJson,
  });

  factory BookSourceModel.fromEntity(BookSource entity) {
    return BookSourceModel(
      id: entity.id,
      name: entity.name,
      bookSourceUrl: entity.bookSourceUrl,
      bookSourceGroup: entity.bookSourceGroup,
      enabled: entity.enabled,
      rulesJson: jsonEncode(entity.rules),
    );
  }

  BookSource toEntity() {
    Map<String, dynamic> rules = {};
    try {
      final decoded = jsonDecode(rulesJson);
      if (decoded is Map) {
        rules = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // 损坏的规则 JSON 降级为空规则
    }
    return BookSource(
      id: id,
      name: name,
      bookSourceUrl: bookSourceUrl,
      bookSourceGroup: bookSourceGroup,
      enabled: enabled,
      rules: rules,
    );
  }
}

/// 手动实现的 Hive TypeAdapter（因 hive_generator 与当前工具链不兼容）
class BookSourceModelAdapter extends TypeAdapter<BookSourceModel> {
  @override
  final int typeId = 1;

  @override
  BookSourceModel read(BinaryReader reader) {
    final numFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numFields; i++) {
      final key = reader.readByte();
      final value = reader.read();
      fields[key] = value;
    }
    // 类型守卫：本地数据损坏/被外部修改时不崩溃
    return BookSourceModel(
      id: fields[0] is String ? fields[0] as String : '',
      name: fields[1] is String ? fields[1] as String : '',
      bookSourceUrl: fields[2] is String ? fields[2] as String : null,
      bookSourceGroup: fields[3] is String ? fields[3] as String : null,
      enabled: fields[4] is bool ? fields[4] as bool : true,
      rulesJson: fields[5] is String ? fields[5] as String : '{}',
    );
  }

  @override
  void write(BinaryWriter writer, BookSourceModel obj) {
    writer.writeByte(6); // 6 fields
    writer.writeByte(0);
    writer.write(obj.id);
    writer.writeByte(1);
    writer.write(obj.name);
    writer.writeByte(2);
    writer.write(obj.bookSourceUrl);
    writer.writeByte(3);
    writer.write(obj.bookSourceGroup);
    writer.writeByte(4);
    writer.write(obj.enabled);
    writer.writeByte(5);
    writer.write(obj.rulesJson);
  }
}
