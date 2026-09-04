import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as parser;

void main() {
  test('相对图片 src 解析为绝对 URL', () {
    const html = '<p>正文</p><img src="/images/a.jpg"><img src="b.png">';
    final resolved = ReaderRepositoryImpl.resolveImageUrls(
      html,
      'https://example.com/chapter/1',
    );
    expect(resolved, contains('https://example.com/images/a.jpg'));
    expect(resolved, contains('https://example.com/chapter/b.png'));
  });

  test('绝对 URL 与 data URI 原样保留', () {
    const html =
        '<img src="https://cdn.example.com/a.jpg">'
        '<img src="data:image/png;base64,AAAA">';
    final resolved = ReaderRepositoryImpl.resolveImageUrls(
      html,
      'https://example.com/chapter/1',
    );
    expect(resolved, contains('https://cdn.example.com/a.jpg'));
    expect(resolved, contains('data:image/png;base64,AAAA'));
  });

  test('无 img 时原样返回，异常输入兜底', () {
    const html = '<p>纯文字</p>';
    expect(ReaderRepositoryImpl.resolveImageUrls(html, 'https://a.com'), html);
    expect(ReaderRepositoryImpl.resolveImageUrls('', 'https://a.com'), '');
  });

  test('§三-4 data-* 懒加载兜底优先于普通 src', () {
    const html = '<img src="/images/placeholder.gif" '
        'data-original="https://cdn.example.com/real.jpg">';
    final resolved = ReaderRepositoryImpl.resolveImageUrls(
      html,
      'https://example.com/chapter/1',
    );
    expect(resolved, contains('https://cdn.example.com/real.jpg'));
    expect(resolved.contains('placeholder.gif'), isFalse);
  });

  test('§三-4 相对 data-* 同样解析为绝对 URL', () {
    const html = '<img data-src="/lazy/pic.jpg">';
    final resolved = ReaderRepositoryImpl.resolveImageUrls(
      html,
      'https://example.com/chapter/1',
    );
    expect(resolved, contains('https://example.com/lazy/pic.jpg'));
  });

  test('§三-4 src 含 ,{json} 选项：URL 解析绝对、参数原样保留', () {
    const html = '<img src=\'https://cdn.example.com/pic?id=1,'
        '{"headers":{"Referer":"https://x"}}\'>';
    final resolved = ReaderRepositoryImpl.resolveImageUrls(
      html,
      'https://example.com/chapter/1',
    );
    expect(resolved, contains('https://cdn.example.com/pic?id=1,'));
    expect(resolved, contains('Referer'));
  });

  test('§三-4 属性实体由解析器解码（&amp;→&）', () {
    const html = '<img src="/img?a=1&amp;b=2">';
    final resolved = ReaderRepositoryImpl.resolveImageUrls(
      html,
      'https://example.com',
    );
    // 序列化会再次转义，用解析器读回验证最终语义
    final doc = parser.parse(resolved);
    expect(
      doc.querySelectorAll('img').first.attributes['src'],
      'https://example.com/img?a=1&b=2',
    );
  });

  test('§三-4 img 其余属性被剥离（归一为 <img src="...">）', () {
    const html = '<img src="/a.jpg" width="100" class="lazy">';
    final resolved = ReaderRepositoryImpl.resolveImageUrls(
      html,
      'https://example.com',
    );
    expect(resolved.contains('width'), isFalse);
    expect(resolved.contains('class'), isFalse);
    expect(resolved, contains('https://example.com/a.jpg'));
  });
}
