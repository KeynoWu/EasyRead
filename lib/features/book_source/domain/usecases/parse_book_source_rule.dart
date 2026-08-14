import 'dart:convert';
import 'package:either_dart/either.dart';
import '../entities/book_source.dart';

/// 解析书源规则 JSON → BookSource 实体
class ParseBookSourceRule {
  /// 无 bookSourceUrl 时基于名称生成稳定 id：同一书源反复导入合并为同一实体，
  /// 避免随机 id 导致重复书源无限累积（与订阅解析 _stableIdFromName 语义一致）。
  static String stableIdFromName(String name) {
    return 'src:${name.toLowerCase().replaceAll(RegExp(r'\s+'), '')}';
  }

  Either<String, BookSource> execute(String jsonString) {
    try {
      final map = jsonDecode(jsonString) as Map<String, dynamic>;
      final name = map['bookSourceName']?.toString().trim() ?? '';
      final url = map['bookSourceUrl']?.toString().trim() ?? '';
      // 既无名称也无地址：视为无效数据拒绝（任意空对象不应生成'未命名书源'）
      if (name.isEmpty && url.isEmpty) {
        return const Left('书源缺少名称和地址');
      }
      final rules = Map<String, dynamic>.from(map);
      rules.remove('bookSourceName');
      rules.remove('bookSourceGroup');
      rules.remove('bookSourceUrl');
      rules.remove('enabled');

      final source = BookSource(
        id: url.isNotEmpty ? url : stableIdFromName(name),
        name: name.isEmpty ? '未命名书源' : name,
        bookSourceUrl: url.isEmpty ? null : url,
        bookSourceGroup: map['bookSourceGroup']?.toString(),
        enabled: BookSource.parseBool(map['enabled']) ?? true,
        rules: rules,
      );
      return Right(source);
    } catch (e) {
      return Left('书源格式错误: $e');
    }
  }
}
