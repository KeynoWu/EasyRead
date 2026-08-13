import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive/hive.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pattern_guard.dart';
import '../../../../core/purification/regex_purifier.dart';
import '../entities/purification_rule.dart';

/// 净化规则管理
class ManagePurificationRules {
  static const String _boxName = 'purification_rules';

  /// 内置规则集 asset 路径（随 app 分发，首次启动导入）
  static const String defaultRulesAsset = 'assets/purification/rules.json';

  /// 默认规则导入标记：区别于"用户删空"，避免用户清空规则后重启复活内置规则。
  static const String _defaultsMarkerKey = '__defaults_imported';

  /// 获取所有规则
  Future<List<PurificationRule>> getAll() async {
    final box = await Hive.openBox<String>(_boxName);
    final rules = <PurificationRule>[];
    for (final value in box.values) {
      try {
        rules.add(_fromJson(jsonDecode(value) as Map<String, dynamic>));
      } catch (_) {
        // 跳过损坏数据
      }
    }
    return rules;
  }

  /// 首次启动：净化规则库为空时从内置 asset 导入默认规则集。
  /// 以导入标记判断是否初始化过：用户清空规则库后不会再次导入。
  Future<void> ensureDefaults() async {
    final box = await Hive.openBox<String>(_boxName);
    if (box.get(_defaultsMarkerKey) == '1') return;
    // 旧版本升级用户：盒内已有规则但无导入标记（旧实现按 isNotEmpty 跳过导入）。
    // 此时视为已初始化，仅补写标记，避免重新导入内置规则覆盖用户数据。
    if (box.isNotEmpty) {
      await box.put(_defaultsMarkerKey, '1');
      return;
    }
    try {
      final raw = await rootBundle.loadString(defaultRulesAsset);
      final list = jsonDecode(raw) as List;
      for (final item in list.cast<Map<String, dynamic>>()) {
        final rule = PurificationRule(
          id: (item['id'] ?? item['name']).toString(),
          name: item['name']?.toString() ?? '未命名',
          pattern: item['pattern']?.toString() ?? '',
          replacement: item['replacement']?.toString() ?? '',
          enabled: _readEnabled(item),
          isRegex: item['isRegex'] as bool? ?? true,
          scopeTitle: item['scopeTitle'] as bool? ?? true,
          scopeContent: item['scopeContent'] as bool? ?? true,
          scope: item['scope']?.toString(),
          excludeScope: item['excludeScope']?.toString(),
          timeoutMillisecond: item['timeoutMillisecond'] is num
              ? (item['timeoutMillisecond'] as num).toInt()
              : null,
          group: item['group']?.toString(),
          order: item['order'] is num ? (item['order'] as num).toInt() : null,
        );
        if (rule.pattern.isEmpty) continue;
        await box.put(rule.id, jsonEncode(_toJson(rule)));
      }
      await box.put(_defaultsMarkerKey, '1');
    } catch (_) {
      // asset 缺失/解析失败：静默跳过，不阻塞启动
    }
  }

  /// 添加规则
  Future<void> add(PurificationRule rule) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.put(rule.id, jsonEncode(_toJson(rule)));
  }

  /// 更新规则
  Future<void> update(PurificationRule rule) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.put(rule.id, jsonEncode(_toJson(rule)));
  }

  /// 删除规则
  Future<void> delete(String id) async {
    final box = await Hive.openBox<String>(_boxName);
    await box.delete(id);
  }

  /// 从 JSON 字符串导入净化规则（支持单个规则对象或规则数组）。
  /// 返回成功导入的规则数；解析失败抛 [FormatException]。
  /// id 与现有规则冲突时自动重编号（后缀 -N），避免覆盖用户已有规则。
  Future<int> importFromJson(String jsonString) async {
    final content = jsonString.trim();
    if (content.isEmpty) {
      throw const FormatException('内容为空');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      throw const FormatException('内容不是有效的 JSON');
    }
    final items = decoded is List
        ? decoded
        : [decoded];
    if (items.isEmpty) throw const FormatException('未找到规则');

    final box = await Hive.openBox<String>(_boxName);
    final existingIds = box.keys.toSet();
    var imported = 0;
    for (final item in items) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      var rule = _fromJson(map);
      if (rule.pattern.isEmpty) continue;
      // id 冲突重编号：保持原 id 可读性，追加 -N 序号避免覆盖
      if (existingIds.contains(rule.id) || rule.id.isEmpty) {
        var n = 1;
        var candidate = rule.id.isEmpty
            ? 'import_${DateTime.now().millisecondsSinceEpoch}'
            : '${rule.id}-1';
        while (existingIds.contains(candidate)) {
          candidate = rule.id.isEmpty
              ? 'import_${DateTime.now().millisecondsSinceEpoch}_$n'
              : '${rule.id}-${++n}';
        }
        rule = rule.copyWith(id: candidate);
        existingIds.add(candidate);
      }
      await box.put(rule.id, jsonEncode(_toJson(rule)));
      imported++;
    }
    if (imported == 0) throw const FormatException('未解析到有效规则');
    return imported;
  }

  /// 从网络 URL 导入净化规则（JSON 文件）。
  /// 走 DioClient：SSRF 私网校验、重定向安全、UA/限频拦截器。
  Future<int> importFromUrl(String url, {DioClient? client}) async {
    final dio = client ?? DioClient();
    final content = await dio.getString(url);
    return importFromJson(content);
  }

  /// 转换为 RegexPurifier 规则列表。
  /// 规则分流：Dart RegExp 可编译且非 @js 替换 → Dart 执行；
  /// 其余（JS lookbehind 语法 / @js 替换）→ [JsPurifyRule]，
  /// 由净化管线在具备 quickjs 引擎时执行，否则跳过。
  Future<RegexPurifier> buildPurifier() async {
    return _buildPurifier(forTitle: false);
  }

  /// 仅构建作用于章节标题的净化规则。
  Future<RegexPurifier> buildTitlePurifier() async {
    return _buildPurifier(forTitle: true);
  }

  Future<RegexPurifier> _buildPurifier({required bool forTitle}) async {
    final rules = await getAll();
    final enabled = <PurifyRule>[];
    final jsRules = <JsPurifyRule>[];
    for (final rule in rules) {
      if (!rule.enabled || rule.pattern.isEmpty) continue;
      if (forTitle && !rule.scopeTitle) continue;
      if (!forTitle && !rule.scopeContent) continue;
      // isRegex=false：pattern 是普通文本，转义正则元字符后按字面量替换，
      // 与正则路径统一走同一执行管线（Dart/JS 分流逻辑一致）
      final pattern = rule.isRegex ? rule.pattern : RegExp.escape(rule.pattern);
      final isJsReplacement = rule.replacement.startsWith('@js:');
      try {
        RegExp(pattern); // 校验正则合法性
        // ReDoS 预检：跳过可能灾难性回溯的历史规则，避免阅读时卡死
        if (!isJsReplacement &&
            PurifyPatternGuard.hasCatastrophicBacktracking(pattern)) {
          continue;
        }
        if (isJsReplacement) {
          jsRules.add(JsPurifyRule(
            pattern: pattern,
            script: rule.replacement.substring(4),
            scope: rule.scope,
            excludeScope: rule.excludeScope,
          ));
        } else {
          enabled.add(PurifyRule(
            pattern: pattern,
            replacement: rule.replacement,
            scope: rule.scope,
            excludeScope: rule.excludeScope,
          ));
        }
      } catch (_) {
        // Dart RegExp 编译失败（如 JS lookbehind 语法）→ 交给 JS 执行器。
        // 普通文本 replacement 作为替换内容保留（JS 引擎逐匹配替换），
        // 而非被当作"空脚本删除匹配"——#06 标点…… 等内置规则依赖此语义
        jsRules.add(JsPurifyRule(
          pattern: pattern,
          script: isJsReplacement ? rule.replacement.substring(4) : '',
          replacement: isJsReplacement ? '' : rule.replacement,
          scope: rule.scope,
          excludeScope: rule.excludeScope,
        ));
      }
    }
    return RegexPurifier(rules: enabled, jsRules: jsRules);
  }

  /// 批量替换文本
  Future<String> applyRules(String text) async {
    final purifier = await buildPurifier();
    return purifier.purify(text);
  }

  static PurificationRule _fromJson(Map<String, dynamic> map) {
    return PurificationRule(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '未命名',
      pattern: map['pattern']?.toString() ?? '',
      replacement: map['replacement']?.toString() ?? '',
      enabled: _readEnabled(map),
      isRegex: map['isRegex'] as bool? ?? true,
      scopeTitle: map['scopeTitle'] as bool? ?? true,
      scopeContent: map['scopeContent'] as bool? ?? true,
      scope: map['scope']?.toString(),
      excludeScope: map['excludeScope']?.toString(),
      timeoutMillisecond: map['timeoutMillisecond'] is num
          ? (map['timeoutMillisecond'] as num).toInt()
          : null,
      group: map['group']?.toString(),
      order: map['order'] is num ? (map['order'] as num).toInt() : null,
    );
  }

  /// 兼容 Hive 的 `enabled` 与外部 Legado 风格 JSON 的 `isEnabled`。
  static bool _readEnabled(Map<String, dynamic> map) {
    final enabled = map['enabled'];
    if (enabled is bool) return enabled;
    final isEnabled = map['isEnabled'];
    return isEnabled is bool ? isEnabled : true;
  }

  static Map<String, dynamic> _toJson(PurificationRule rule) {
    return {
      'id': rule.id,
      'name': rule.name,
      'pattern': rule.pattern,
      'replacement': rule.replacement,
      'enabled': rule.enabled,
      'isRegex': rule.isRegex,
      'scopeTitle': rule.scopeTitle,
      'scopeContent': rule.scopeContent,
      if (rule.scope != null) 'scope': rule.scope,
      if (rule.excludeScope != null) 'excludeScope': rule.excludeScope,
      if (rule.timeoutMillisecond != null)
        'timeoutMillisecond': rule.timeoutMillisecond,
      if (rule.group != null) 'group': rule.group,
      if (rule.order != null) 'order': rule.order,
    };
  }
}
