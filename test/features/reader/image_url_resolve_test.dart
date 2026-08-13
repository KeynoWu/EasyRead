import 'package:easy_read/features/reader/data/repositories/reader_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
