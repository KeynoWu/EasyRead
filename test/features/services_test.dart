import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:easy_read/features/search/data/services/search_history_service.dart';

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_test').path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  group('SearchHistoryService', () {
    test('should add and retrieve keywords (newest first)', () async {
      final service = SearchHistoryService();
      await service.add('斗破苍穹');
      await service.add('凡人修仙传');
      await service.add('斗破苍穹'); // 重复去重

      final recent = await service.getRecent();
      expect(recent.length, 2);
      expect(recent[0], '斗破苍穹'); // 最新在前
      expect(recent[1], '凡人修仙传');
    });

    test('should clear history', () async {
      final service = SearchHistoryService();
      await service.add('测试');
      await service.clear();
      expect(await service.getRecent(), isEmpty);
    });
  });
}
