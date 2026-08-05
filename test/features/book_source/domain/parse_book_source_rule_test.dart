import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/book_source/domain/usecases/parse_book_source_rule.dart';

void main() {
  late ParseBookSourceRule useCase;

  setUp(() {
    useCase = ParseBookSourceRule();
  });

  test('should parse valid JSON book source', () {
    const json = '''
    {
      "bookSourceName": "测试源",
      "bookSourceGroup": "通用",
      "searchUrl": "https://test.com/search?keyword={{key}}",
      "bookList": "div.list > .item",
      "bookName": "h2.title@text",
      "bookAuthor": "span.author@text",
      "coverUrl": "img.cover@src",
      "bookDetailUrl": "a.link@href",
      "contentUrl": "https://test.com/chapter/{{id}}.html",
      "chapterList": "ul.chapters > li",
      "chapterName": "a@text",
      "chapterUrl": "a@href",
      "chapterContent": "div.content@html"
    }
    ''';
    final result = useCase.execute(json);
    expect(result.isRight, true);
    result.fold(
      (l) => fail('Expected Right'),
      (source) {
        expect(source.name, '测试源');
        expect(source.bookSourceGroup, '通用');
        expect(source.searchUrl, contains('{{key}}'));
      },
    );
  });

  test('should return error for invalid JSON', () {
    const json = '{invalid json}';
    final result = useCase.execute(json);
    expect(result.isLeft, true);
  });

  test('should parse string boolean enabled value', () {
    const json = '''
    {
      "bookSourceName": "禁用源",
      "bookSourceUrl": "https://test.com",
      "enabled": "false",
      "searchUrl": "https://test.com/search?keyword={{key}}"
    }
    ''';
    final result = useCase.execute(json);
    expect(result.isRight, true);
    result.fold(
      (l) => fail('Expected Right'),
      (source) {
        expect(source.enabled, isFalse);
        expect(source.rules.containsKey('enabled'), isFalse);
      },
    );
  });
}
