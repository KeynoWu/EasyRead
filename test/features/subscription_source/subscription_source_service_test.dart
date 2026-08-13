import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/features/subscription_source/data/services/subscription_source_service.dart';
import 'package:easy_read/features/subscription_source/domain/entities/subscription_source.dart';

void main() {
  late Directory tempDir;
  late SubscriptionSourceService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('subscription_source_test');
    Hive.init(tempDir.path);
    service = SubscriptionSourceService();
  });

  tearDown(() async {
    await Hive.close();
    await Hive.deleteFromDisk();
    tempDir.deleteSync(recursive: true);
  });

  SubscriptionSource makeSource(String id, String name,
          {String? group, DateTime? lastUpdatedAt}) =>
      SubscriptionSource(
        id: id,
        name: name,
        url: 'https://example.com/$id.xml',
        group: group,
        lastUpdatedAt: lastUpdatedAt,
      );

  test('CRUD：新增 / 查询 / 列表 / 删除', () async {
    await service.save(makeSource('a', '源A'));
    await service.save(makeSource('b', '源B', group: '科技'));

    final found = await service.getById('a');
    expect(found, isNotNull);
    expect(found!.name, '源A');
    expect(found.url, 'https://example.com/a.xml');
    expect(found.group, isNull);

    final all = await service.getAll();
    expect(all, hasLength(2));
    expect(all.map((s) => s.name), containsAll(['源A', '源B']));

    await service.remove('a');
    expect(await service.getById('a'), isNull);
    expect(await service.getAll(), hasLength(1));
    expect((await service.getAll()).single.id, 'b');
  });

  test('更新：save 同 id 覆盖旧数据', () async {
    await service.save(makeSource('a', '旧名'));
    await service.save(
        const SubscriptionSource(id: 'a', name: '新名', url: 'https://example.com/a.xml', group: '分组'));
    final updated = await service.getById('a');
    expect(updated!.name, '新名');
    expect(updated.group, '分组');
    expect(updated.url, 'https://example.com/a.xml');
  });

  test('lastUpdatedAt 更新', () async {
    await service.save(makeSource('a', '源A'));
    expect((await service.getById('a'))!.lastUpdatedAt, isNull);

    final t1 = DateTime.utc(2024, 1, 1, 10, 0);
    await service.updateLastUpdatedAt('a', t1);
    expect((await service.getById('a'))!.lastUpdatedAt, t1);

    final t2 = DateTime.utc(2024, 1, 2, 12, 0);
    await service.updateLastUpdatedAt('a', t2);
    expect((await service.getById('a'))!.lastUpdatedAt, t2);
  });

  test('updateLastUpdatedAt 对不存在的源静默忽略', () async {
    await service.updateLastUpdatedAt('ghost', DateTime.utc(2024, 1, 1));
    expect(await service.getById('ghost'), isNull);
    expect(await service.getAll(), isEmpty);
  });

  test('损坏数据跳过，不影响其它条目', () async {
    await service.save(makeSource('a', '源A'));
    final box = await Hive.openBox<String>(SubscriptionSourceService.boxName);
    await box.put('bad', '{not valid json');
    await box.put('bad2', '');

    final all = await service.getAll();
    expect(all, hasLength(1));
    expect(all.single.id, 'a');
    expect(await service.getById('bad'), isNull);
  });

  test('getAll 按名称排序', () async {
    await service.save(makeSource('b', '乙源'));
    await service.save(makeSource('a', '甲源'));
    await service.save(makeSource('c', '丙源'));
    final all = await service.getAll();
    // String.compareTo 按 UTF-16 码元：丙(4E19) < 乙(4E59) < 甲(7532)
    expect(all.map((s) => s.name).toList(), ['丙源', '乙源', '甲源']);
  });

  test('lastUpdatedAt 序列化往返保持一致', () async {
    final t = DateTime.utc(2024, 5, 6, 7, 8, 9);
    await service.save(makeSource('a', '源A', group: '工具', lastUpdatedAt: t));
    final reloaded = await service.getById('a');
    expect(reloaded!.group, '工具');
    expect(reloaded.lastUpdatedAt, t);
  });
}
