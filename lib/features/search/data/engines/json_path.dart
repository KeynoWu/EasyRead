import 'dart:convert';

/// JSONPath 引擎 — 支持 Legado 常用子集：
/// - `$` 根、`.key` 属性、`['key']` 属性
/// - `..key` 递归下降（收集所有层级的 key）
/// - `[*]` 展开数组、`[N]` 索引
/// - `expr1&&expr2` 组合：前一个无结果时用后一个（Legado 语义）
/// - `@` 当前节点（过滤表达式预留，暂不实现）
class JsonPathEngine {
  static final JsonPathEngine instance = JsonPathEngine();

  /// 查询 JSON 数据，返回匹配值列表（空 = 无结果）
  List<dynamic> query(dynamic data, String path) {
    if (path.isEmpty) return [];
    // Legado && 组合：取第一个有结果的表达式
    if (path.contains('&&')) {
      for (final expr in path.split('&&')) {
        final result = _querySingle(data, expr.trim());
        if (result.isNotEmpty) return result;
      }
      return [];
    }
    return _querySingle(data, path);
  }

  List<dynamic> _querySingle(dynamic data, String path) {
    final steps = _parse(path);
    if (steps.isEmpty) return [];
    var current = <dynamic>[data];
    for (final step in steps) {
      current = _applyStep(current, step);
      if (current.isEmpty) return [];
    }
    return current;
  }

  List<dynamic> _applyStep(List<dynamic> current, _Step step) {
    final result = <dynamic>[];
    switch (step) {
      case _KeyStep(:final key):
        for (final node in current) {
          if (node is Map) {
            final value = node[key];
            if (value != null) result.add(value);
          }
        }
      case _RecursiveStep(:final key):
        for (final node in current) {
          _collectRecursive(node, key, result);
        }
      case _AllStep():
        for (final node in current) {
          if (node is List) result.addAll(node);
        }
      case _IndexStep(:final index):
        for (final node in current) {
          if (node is List && index >= 0 && index < node.length) {
            result.add(node[index]);
          }
        }
    }
    return result;
  }

  /// 递归收集所有层级 Map 中 [key] 的值
  void _collectRecursive(dynamic node, String key, List<dynamic> out) {
    if (node is Map) {
      final value = node[key];
      if (value != null) out.add(value);
      for (final child in node.values) {
        _collectRecursive(child, key, out);
      }
    } else if (node is List) {
      for (final child in node) {
        _collectRecursive(child, key, out);
      }
    }
  }

  List<_Step> _parse(String path) {
    var rest = path.trim();
    if (rest.startsWith(r'$')) rest = rest.substring(1);
    final steps = <_Step>[];
    while (rest.isNotEmpty) {
      if (rest.startsWith('..')) {
        rest = rest.substring(2);
        final (key, remaining) = _readKey(rest);
        if (key == null) return [];
        rest = remaining;
        steps.add(_RecursiveStep(key));
      } else if (rest.startsWith('.')) {
        rest = rest.substring(1);
        final (key, remaining) = _readKey(rest);
        if (key == null) return [];
        rest = remaining;
        steps.add(_KeyStep(key));
      } else if (rest.startsWith('[')) {
        final close = rest.indexOf(']');
        if (close < 0) return [];
        final inner = rest.substring(1, close).trim();
        rest = rest.substring(close + 1);
        if (inner == '*') {
          steps.add(_AllStep());
        } else {
          final index = int.tryParse(inner);
          if (index == null) return [];
          steps.add(_IndexStep(index));
        }
      } else if (rest.startsWith('?')) {
        // 过滤表达式（暂不支持）：跳过该段避免崩溃
        final close = rest.indexOf(')');
        if (close < 0) return [];
        rest = rest.substring(close + 1);
      } else {
        return [];
      }
    }
    return steps;
  }

  /// 读取属性名（.key 或 ['key']），返回 (属性名, 剩余路径)
  (String?, String) _readKey(String rest) {
    if (rest.startsWith("['")) {
      final close = rest.indexOf("']");
      if (close < 0) return (null, rest);
      return (rest.substring(2, close), rest.substring(close + 2));
    }
    final match = RegExp(r'^[A-Za-z0-9_\u4e00-\u9fa5]+').firstMatch(rest);
    if (match == null) return (null, rest);
    return (match.group(0), rest.substring(match.end));
  }

  /// 便捷：解析字符串为 JSON 后查询
  static List<dynamic> queryString(String json, String path) {
    try {
      return instance.query(jsonDecode(json), path);
    } catch (_) {
      return [];
    }
  }
}

sealed class _Step {}

class _KeyStep extends _Step {
  final String key;
  _KeyStep(this.key);
}

class _RecursiveStep extends _Step {
  final String key;
  _RecursiveStep(this.key);
}

class _AllStep extends _Step {
  _AllStep();
}

class _IndexStep extends _Step {
  final int index;
  _IndexStep(this.index);
}
