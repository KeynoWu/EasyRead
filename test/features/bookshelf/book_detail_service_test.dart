import 'dart:io';
import 'package:easy_read/features/bookshelf/data/services/book_detail_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  setUp(() async {
    Hive.init(Directory.systemTemp.createTempSync('hive_book_detail_test').path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('should save and restore book details', () async {
    final service = BookDetailService();
    await service.save(
      'book1',
      detailUrl: 'https://example.com/book/1',
      alternativesJson: '[]',
      variablesJson: '{"token":"abc"}',
    );

    final detail = await service.get('book1');
    expect(detail, isNotNull);
    expect(detail!.detailUrl, 'https://example.com/book/1');
    expect(detail.alternativesJson, '[]');
    expect(detail.variablesJson, '{"token":"abc"}');
  });

  test('decodeVariables 解析书源变量 JSON', () {
    expect(
      BookDetail.decodeVariables('{"token":"abc","page":"2"}'),
      {'token': 'abc', 'page': '2'},
    );
    expect(BookDetail.decodeVariables(null), isEmpty);
    expect(BookDetail.decodeVariables('not-json'), isEmpty);
  });

  test('should remove book details', () async {
    final service = BookDetailService();
    await service.save('book1', detailUrl: 'https://example.com/book/1');
    await service.remove('book1');
    expect(await service.get('book1'), isNull);
  });
}
