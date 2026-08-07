import 'rule_engine.dart';

/// Legado/阅读 3.0 `@put:` / `@get:` 变量规则。
///
/// `字段规则@put:{key:提取规则}` 先把提取规则的结果写入变量，再返回字段值；
/// `@get:{key}` 在 URL/规则字符串中展开为已保存的变量。
class RuleVariables {
  static final _putPattern = RegExp(r'@put:\{([^{}]+)\}', caseSensitive: false);
  static final _getPattern = RegExp(r'@get:\{([^{}]+)\}', caseSensitive: false);

  /// 展开字符串中的 `@get:{key}`；未保存的变量按空字符串处理。
  static String expand(String text, Map<String, String> variables) {
    if (!text.contains('@get:')) return text;
    return text.replaceAllMapped(_getPattern, (match) {
      final key = match.group(1)!.trim();
      return variables[key] ?? '';
    });
  }

  /// 从字段规则中移除 `@put:{...}`，并把每个 put 值规则的结果写入变量。
  /// 返回去掉 put 后缀后的基础规则；没有 put 时原样返回。
  static String collectAndStrip(
    String rule,
    dynamic item,
    Map<String, String> variables,
  ) {
    if (!rule.contains('@put:')) return rule;
    return rule.replaceAllMapped(_putPattern, (match) {
      for (final entry in _parsePut(match.group(1)!)) {
        final value = RuleEngine.getElementText(item, entry.$2);
        if (value != null && value.isNotEmpty) {
          variables[entry.$1] = value;
        }
      }
      return '';
    }).trim();
  }

  static List<(String, String)> _parsePut(String body) {
    final normalized = body.trim();
    if (normalized.startsWith('{') && normalized.endsWith('}')) {
      return _parsePut(normalized.substring(1, normalized.length - 1));
    }
    final entries = <(String, String)>[];
    for (final raw in normalized.split(RegExp(r'[,;]'))) {
      final item = raw.trim();
      if (item.isEmpty) continue;
      final colon = item.indexOf(':');
      if (colon <= 0) continue;
      final key = item.substring(0, colon).trim();
      final value = item.substring(colon + 1).trim();
      if (key.isNotEmpty && value.isNotEmpty) {
        entries.add((key, value));
      }
    }
    return entries;
  }
}
