import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
// ignore_for_file: experimental_member_use — HiveList 为接口签名必需
import 'package:hive/hive.dart';
import 'package:easy_read/features/book_source/data/models/source_subscription_model.dart';

/// 最小内存 BinaryWriter：编码规则与 Hive 一致（uint32 4B 大端 / int 8B double / bool 1B / string 4B 长度+utf8）
class _MemWriter implements BinaryWriter {
  final BytesBuilder _b = BytesBuilder();

  List<int> toBytes() => _b.toBytes();

  void _add4(int value) {
    _b.add((ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List());
  }

  @override
  void writeByte(int byte) => _b.addByte(byte & 0xFF);

  @override
  void writeWord(int value) {
    final d = ByteData(2)..setUint16(0, value);
    _b.add(d.buffer.asUint8List());
  }

  @override
  void writeInt32(int value) {
    final d = ByteData(4)..setInt32(0, value);
    _b.add(d.buffer.asUint8List());
  }

  @override
  void writeUint32(int value) => _add4(value);

  @override
  void writeInt(int value) => writeDouble(value.toDouble());

  @override
  void writeDouble(double value) {
    final d = ByteData(8)..setFloat64(0, value);
    _b.add(d.buffer.asUint8List());
  }

  @override
  void writeBool(bool value) => writeByte(value ? 1 : 0);

  @override
  void writeString(
    String value, {
    bool writeByteCount = true,
    Converter<String, List<int>> encoder = BinaryWriter.utf8Encoder,
  }) {
    final bytes = encoder.convert(value);
    if (writeByteCount) writeUint32(bytes.length);
    _b.add(bytes);
  }

  @override
  void writeByteList(List<int> bytes, {bool writeLength = true}) {
    if (writeLength) writeUint32(bytes.length);
    _b.add(bytes);
  }

  @override
  void write<T>(T value, {bool writeTypeId = true}) =>
      throw UnimplementedError('not used');

  @override
  void writeBoolList(List<bool> list, {bool writeLength = true}) =>
      throw UnimplementedError('not used');

  @override
  void writeDoubleList(List<double> list, {bool writeLength = true}) =>
      throw UnimplementedError('not used');

  @override
  void writeHiveList(HiveList list, {bool writeLength = true}) =>
      throw UnimplementedError('not used');

  @override
  void writeIntList(List<int> list, {bool writeLength = true}) =>
      throw UnimplementedError('not used');

  @override
  void writeList(List list, {bool writeLength = true}) =>
      throw UnimplementedError('not used');

  @override
  void writeMap(Map map, {bool writeLength = true}) =>
      throw UnimplementedError('not used');

  @override
  void writeStringList(
    List<String> list, {
    bool writeLength = true,
    Converter<String, List<int>> encoder = BinaryWriter.utf8Encoder,
  }) =>
      throw UnimplementedError('not used');
}

/// 最小内存 BinaryReader：与 _MemWriter 对称
class _MemReader implements BinaryReader {
  final ByteData _data;
  int _offset = 0;

  _MemReader(List<int> bytes) : _data = ByteData.view(Uint8List.fromList(bytes).buffer);

  static const _utf8Decoder = Utf8Decoder();

  @override
  int get availableBytes => _data.lengthInBytes - _offset;

  @override
  int get usedBytes => _offset;

  @override
  void skip(int bytes) => _offset += bytes;

  @override
  int readByte() => _data.getUint8(_offset++);

  @override
  Uint8List viewBytes(int bytes) {
    final v = _data.buffer.asUint8List(_data.offsetInBytes + _offset, bytes);
    _offset += bytes;
    return v;
  }

  @override
  Uint8List peekBytes(int bytes) =>
      _data.buffer.asUint8List(_data.offsetInBytes + _offset, bytes);

  @override
  int readWord() {
    final v = _data.getUint16(_offset);
    _offset += 2;
    return v;
  }

  @override
  int readInt32() {
    final v = _data.getInt32(_offset);
    _offset += 4;
    return v;
  }

  @override
  int readUint32() {
    final v = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  @override
  int readInt() => readDouble().toInt();

  @override
  double readDouble() {
    final v = _data.getFloat64(_offset);
    _offset += 8;
    return v;
  }

  @override
  bool readBool() => readByte() > 0;

  @override
  String readString([
    int? byteCount,
    Converter<List<int>, String> decoder = _utf8Decoder,
  ]) {
    byteCount ??= readUint32();
    return decoder.convert(viewBytes(byteCount));
  }

  @override
  Uint8List readByteList([int? length]) {
    length ??= readUint32();
    return viewBytes(length);
  }

  @override
  dynamic read([int? typeId]) {
    typeId ??= readByte();
    switch (typeId) {
      case 0: // null
        return null;
      case 4: // String
        return readString();
      default:
        throw UnimplementedError('test reader: 未支持类型 $typeId');
    }
  }

  @override
  List<bool> readBoolList([int? length]) =>
      throw UnimplementedError('not used');

  @override
  List<double> readDoubleList([int? length]) =>
      throw UnimplementedError('not used');

  @override
  HiveList readHiveList([int? length]) =>
      throw UnimplementedError('not used');

  @override
  List<int> readIntList([int? length]) =>
      throw UnimplementedError('not used');

  @override
  List readList([int? length]) => throw UnimplementedError('not used');

  @override
  Map readMap([int? length]) => throw UnimplementedError('not used');

  @override
  List<String> readStringList([
    int? length,
    Converter<List<int>, String> decoder = _utf8Decoder,
  ]) =>
      throw UnimplementedError('not used');
}

/// 旧版位置式编码（v1 格式）——模拟升级前的磁盘字节
List<int> legacyEncode(SourceSubscriptionModel m) {
  final w = _MemWriter();
  w.writeString(m.id);
  w.writeString(m.name);
  w.writeString(m.url);
  w.writeBool(m.lastUpdatedAt != null);
  if (m.lastUpdatedAt != null) w.writeInt(m.lastUpdatedAt!.millisecondsSinceEpoch);
  w.writeBool(m.lastUpdateResult != null);
  if (m.lastUpdateResult != null) w.writeString(m.lastUpdateResult!);
  return w.toBytes();
}

void main() {
  final adapter = SourceSubscriptionModelAdapter();
  const ts = 1700000000000;

  test('新版字段式格式读写自洽（含空字段）', () {
    final w = _MemWriter();
    adapter.write(w, SourceSubscriptionModel(
      id: 's1', name: '新订阅', url: 'https://example.com/feed',
      lastUpdatedAt: DateTime.fromMillisecondsSinceEpoch(ts),
      lastUpdateResult: '更新失败: 连接超时',
    ));
    final read = adapter.read(_MemReader(w.toBytes()));
    expect(read.id, 's1');
    expect(read.name, '新订阅');
    expect(read.url, 'https://example.com/feed');
    expect(read.lastUpdatedAt, DateTime.fromMillisecondsSinceEpoch(ts));
    expect(read.lastUpdateResult, '更新失败: 连接超时');

    final w2 = _MemWriter();
    adapter.write(w2, SourceSubscriptionModel(id: 's2', name: '空', url: ''));
    final read2 = adapter.read(_MemReader(w2.toBytes()));
    expect(read2.id, 's2');
    expect(read2.lastUpdatedAt, isNull);
    expect(read2.lastUpdateResult, isNull);
  });

  test('旧版位置式格式可被新版 adapter 兼容读取', () {
    final bytes = legacyEncode(SourceSubscriptionModel(
      id: 'legacy-1', name: '旧订阅', url: 'http://old.example.com/feed',
      lastUpdatedAt: DateTime.fromMillisecondsSinceEpoch(ts),
      lastUpdateResult: '成功更新 3 个书源',
    ));
    final read = adapter.read(_MemReader(bytes));
    expect(read.id, 'legacy-1');
    expect(read.name, '旧订阅');
    expect(read.url, 'http://old.example.com/feed');
    expect(read.lastUpdatedAt, DateTime.fromMillisecondsSinceEpoch(ts));
    expect(read.lastUpdateResult, '成功更新 3 个书源');
  });

  test('旧版格式空字段兼容读取', () {
    final bytes = legacyEncode(SourceSubscriptionModel(id: 'x', name: 'n', url: 'u'));
    final read = adapter.read(_MemReader(bytes));
    expect(read.id, 'x');
    expect(read.lastUpdatedAt, isNull);
    expect(read.lastUpdateResult, isNull);
  });

  test('新版格式损坏字段降级不崩溃（未知字段键在末尾时被忽略）', () {
    // 手工构造：魔数 + 字段数 + 已知键 + 末尾未知键（约定未来扩展字段只追加末尾）
    final w = _MemWriter();
    w.writeByte(0x7F);
    w.writeByte(4);
    w.writeByte(0);
    w.writeString('id-ok');
    w.writeByte(1);
    w.writeString('name-ok');
    w.writeByte(99); // 未知字段键（值用类型化编码：stringT=4 + raw 字符串）
    w.writeByte(4);
    w.writeString('future-value');
    w.writeByte(98);
    w.writeByte(4);
    w.writeString('another');
    final read = adapter.read(_MemReader(w.toBytes()));
    expect(read.id, 'id-ok');
    expect(read.name, 'name-ok');
    expect(read.lastUpdatedAt, isNull);
  });

group('真实 Hive 盒级兼容', () {
  test('旧 adapter 写入的盒可被新 adapter 读取', () async {
    final tempDir = Directory.systemTemp.createTempSync('hive_adapter_box');
    Hive.init(tempDir.path);

    // 1. 用旧版 adapter 写入（模拟升级前数据）
    Hive.registerAdapter(_LegacyAdapter(), override: true);
    final legacyBox = await Hive.openBox<SourceSubscriptionModel>('subs');
    await legacyBox.put('k1', SourceSubscriptionModel(
      id: 'legacy-1',
      name: '旧订阅',
      url: 'http://old.example.com/feed',
      lastUpdatedAt: DateTime.fromMillisecondsSinceEpoch(ts),
      lastUpdateResult: '成功更新 3 个书源',
    ));
    await legacyBox.put('k2',
        SourceSubscriptionModel(id: 'legacy-2', name: '无状态订阅', url: 'https://x.example/feed'));
    await legacyBox.close();

    // 2. 换新版 adapter 读取（模拟升级后启动）
    Hive.registerAdapter(SourceSubscriptionModelAdapter(), override: true);
    final box = await Hive.openBox<SourceSubscriptionModel>('subs');

    final full = box.get('k1');
    expect(full, isNotNull);
    expect(full!.id, 'legacy-1');
    expect(full.name, '旧订阅');
    expect(full.url, 'http://old.example.com/feed');
    expect(full.lastUpdatedAt, DateTime.fromMillisecondsSinceEpoch(ts));
    expect(full.lastUpdateResult, '成功更新 3 个书源');

    final minimal = box.get('k2');
    expect(minimal, isNotNull);
    expect(minimal!.id, 'legacy-2');
    expect(minimal.lastUpdatedAt, isNull);
    expect(minimal.lastUpdateResult, isNull);

    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });
});

}

/// 旧版位置式 TypeAdapter（v1 格式）——模拟升级前应用写入的真实磁盘数据
class _LegacyAdapter extends TypeAdapter<SourceSubscriptionModel> {
  @override
  final int typeId = 4;

  @override
  SourceSubscriptionModel read(BinaryReader reader) {
    return SourceSubscriptionModel(
      id: reader.readString(),
      name: reader.readString(),
      url: reader.readString(),
      lastUpdatedAt: reader.readBool()
          ? DateTime.fromMillisecondsSinceEpoch(reader.readInt())
          : null,
      lastUpdateResult: reader.readBool() ? reader.readString() : null,
    );
  }

  @override
  void write(BinaryWriter writer, SourceSubscriptionModel obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.name);
    writer.writeString(obj.url);
    writer.writeBool(obj.lastUpdatedAt != null);
    if (obj.lastUpdatedAt != null) {
      writer.writeInt(obj.lastUpdatedAt!.millisecondsSinceEpoch);
    }
    writer.writeBool(obj.lastUpdateResult != null);
    if (obj.lastUpdateResult != null) {
      writer.writeString(obj.lastUpdateResult!);
    }
  }
}
