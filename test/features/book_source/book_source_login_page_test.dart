import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/presentation/pages/book_source_login_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('登录 URL 相对路径基于书源域名解析', () {
    const source = BookSource(
      id: 'src1',
      name: '源',
      bookSourceUrl: 'https://example.com',
      rules: {'loginUrl': '/login'},
    );
    expect(
      BookSourceLoginPage.resolveLoginUrl(source),
      'https://example.com/login',
    );
  });

  test('登录 URL 去掉 Legado JSON 参数', () {
    const source = BookSource(
      id: 'src2',
      name: '源',
      bookSourceUrl: 'https://example.com',
      rules: {
        'loginUrl': "/login,{'method':'POST','body':'u=x'}",
      },
    );
    expect(
      BookSourceLoginPage.resolveLoginUrl(source),
      'https://example.com/login',
    );
  });

  test('绝对登录 URL 原样使用', () {
    const source = BookSource(
      id: 'src3',
      name: '源',
      bookSourceUrl: 'https://example.com',
      rules: {'loginUrl': 'https://auth.example.net/signin'},
    );
    expect(
      BookSourceLoginPage.resolveLoginUrl(source),
      'https://auth.example.net/signin',
    );
  });

  test('没有 loginUrl 时回退到书源地址', () {
    const source = BookSource(
      id: 'src4',
      name: '源',
      bookSourceUrl: 'https://example.com',
    );
    expect(
      BookSourceLoginPage.resolveLoginUrl(source),
      'https://example.com',
    );
  });
}
