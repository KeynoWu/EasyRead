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

  test('should parse Legado nested rules (ruleSearch/ruleToc/ruleContent)', () {
    // Legado 标准格式：正文规则在 ruleContent 容器内（contentUrl 嵌套）
    const json = '''
    {
      "bookSourceName": "嵌套源",
      "bookSourceUrl": "https://test.com",
      "ruleSearch": {
        "url": "https://test.com/search?keyword={{key}}",
        "bookList": "div.list > .item",
        "name": "h2.title@text",
        "author": "span.author@text",
        "coverUrl": "img.cover@src",
        "bookUrl": "a.link@href"
      },
      "ruleToc": {
        "chapterList": "ul.chapters > li",
        "chapterName": "a@text",
        "chapterUrl": "a@href"
      },
      "ruleContent": {
        "content": "div.content@html",
        "contentUrl": "https://test.com/chapter/{{id}}.html"
      }
    }
    ''';
    final result = useCase.execute(json);
    expect(result.isRight, true);
    result.fold(
      (l) => fail('Expected Right'),
      (source) {
        expect(source.searchUrl, contains('{{key}}'));
        expect(source.bookListRule, 'div.list > .item');
        expect(source.chapterListRule, 'ul.chapters > li');
        expect(source.chapterContentRule, 'div.content@html');
        expect(source.contentUrl, 'https://test.com/chapter/{{id}}.html');
      },
    );
  });
}
