import 'dart:convert';
import 'package:hive/hive.dart';
import '../../../../core/purification/regex_purifier.dart';
import '../entities/purification_rule.dart';

/// 净化规则管理
class ManagePurificationRules {
  static const String _boxName = 'purification_rules';

  /// 获取所有规则
  Future<List<PurificationRule>> getAll() async {
    final box = await Hive.openBox<String>(_boxName);
    final rules = <PurificationRule>[];
    for (final value in box.values) {
      try {
        final map = jsonDecode(value) as Map<String, dynamic>;
        rules.add(PurificationRule(
          id: map['id']?.toString() ?? '',
          name: map['name']?.toString() ?? '未命名',
          pattern: map['pattern']?.toString() ?? '',
          replacement: map['replacement']?.toString() ?? '',
          enabled: map['enabled'] as bool? ?? true,
        ));
      } catch (_) {
        // 跳过损坏数据
      }
    }
    return rules;
  }

  /// 添加规则
  Future<void> add(PurificationRule rule) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.put(rule.id, jsonEncode({
      'id': rule.id,
      'name': rule.name,
      'pattern': rule.pattern,
      'replacement': rule.replacement,
      'enabled': rule.enabled,
    }));
  }

  /// 更新规则
  Future<void> update(PurificationRule rule) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.put(rule.id, jsonEncode({
      'id': rule.id,
      'name': rule.name,
      'pattern': rule.pattern,
      'replacement': rule.replacement,
      'enabled': rule.enabled,
    }));
  }

  /// 删除规则
  Future<void> delete(String id) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.delete(id);
  }

  /// 转换为 RegexPurifier 规则列表
  Future<RegexPurifier> buildPurifier() async {
    final rules = await getAll();
    return RegexPurifier(rules: rules.where((r) => r.enabled).map((r) {
      return PurifyRule(pattern: r.pattern, replacement: r.replacement);
    }).toList());
  }

  /// 批量替换文本
  Future<String> applyRules(String text) async {
    final purifier = await buildPurifier();
    return purifier.purify(text);
  }
}
