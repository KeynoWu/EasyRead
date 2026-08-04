import 'dart:convert';
import 'package:either_dart/either.dart';
import '../entities/book_source.dart';

/// 解析书源规则 JSON → BookSource 实体
class ParseBookSourceRule {
  Either<String, BookSource> execute(String jsonString) {
    try {
      final map = jsonDecode(jsonString) as Map<String, dynamic>;
      final rules = Map<String, dynamic>.from(map);
      rules.remove('bookSourceName');
      rules.remove('bookSourceGroup');
      rules.remove('bookSourceUrl');

      final source = BookSource(
        id: map['bookSourceUrl']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: map['bookSourceName']?.toString() ?? '未命名书源',
        bookSourceUrl: map['bookSourceUrl']?.toString(),
        bookSourceGroup: map['bookSourceGroup']?.toString(),
        rules: rules,
      );
      return Right(source);
    } catch (e) {
      return Left('书源格式错误: $e');
    }
  }
}
