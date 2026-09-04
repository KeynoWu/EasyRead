/// 规则语法解析与判定：规则类型识别、分隔拆分、级联/索引解析。
/// 纯字符串/正则处理，不执行任何查询；输出由 [SelectorEngine] 消费。
class RuleParser {
  /// 级联解析缓存（规则字符串有限，防每次查询重复解析）。
  /// 上限 [_cascadeCacheMax]：导入大量不同选择器时防止无界增长（超限清空，
  /// 解析代价远低于内存失控）。
  static final Map<String, List<CascadeStep>> _cascadeCache = {};
  static const int _cascadeCacheMax = 512;

  static void _putCascadeCache(String selector, List<CascadeStep> steps) {
    if (_cascadeCache.length >= _cascadeCacheMax &&
        !_cascadeCache.containsKey(selector)) {
      _cascadeCache.clear();
    }
    _cascadeCache[selector] = steps;
  }

  /// 相对路径规范化：`name` → `.name`（JsonPathEngine 需 . 或 [ 开头）
  static String normalizeJsonPath(String rule) {
    final t = rule.trim();
    if (t.toLowerCase().startsWith('@json:')) return t.substring(6).trim();
    if (t.startsWith(r'$') || t.startsWith('.') || t.startsWith('[')) return t;
    return '.$t';
  }

  /// 规则是否 JSONPath 模式（$ 或 @json: 开头）
  static bool isJsonPath(String rule) {
    final t = rule.trim();
    return t.startsWith(r'$') || t.toLowerCase().startsWith('@json:');
  }

  /// 规则无任何模式前缀（JS/CSS/JSONPath/XPath/AllInOne）：
  /// 内容为 JSON 时裸规则默认走 JSONPath（Legado isJSON 分支）
  static bool isBareRule(String rule) {
    final t = rule.trim();
    return !isJsRule(t) &&
        !isCssRule(t) &&
        !isJsonPath(t) &&
        !isXPathRule(t) &&
        !isAllInOneRule(t);
  }

  /// 内容是否 JSON 形态（首个非空白字符为 { 或 [）
  static bool looksLikeJson(String content) {
    for (var i = 0; i < content.length && i < 64; i++) {
      final c = content.codeUnitAt(i);
      if (c == 0x7B || c == 0x5B) return true; // { [
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) return false;
    }
    return false;
  }

  /// 规则是否 CSS 模式（@css: 开头）
  static bool isCssRule(String rule) {
    final t = rule.trim();
    return t.toLowerCase().startsWith('@css:');
  }

  /// 规则是否 XPath 模式（// 或 @XPath: 开头）
  static bool isXPathRule(String rule) {
    final t = rule.trim();
    return t.startsWith('/') || t.toLowerCase().startsWith('@xpath:');
  }

  /// 规则是否 Legado AllInOne 正则列表模式（`:正则1&&正则2`）。
  static bool isAllInOneRule(String rule) {
    final t = rule.trim();
    return t.startsWith(':') && !RuleParser.isJsRule(t);
  }

  static String allInOneOf(String rule) => rule.trim().substring(1).trim();

  static String xpathOf(String rule) {
    final t = rule.trim();
    if (t.toLowerCase().startsWith('@xpath:')) return t.substring(7).trim();
    return t;
  }

  static String cssRuleOf(String rule) => rule.trim().substring(5).trim();

  static String jsonPathOf(String rule) {
    final t = rule.trim();
    if (t.toLowerCase().startsWith('@json:')) return t.substring(6).trim();
    return t;
  }

  /// 规则是否 JS 模板模式（js 标签包裹或 at-js 前缀）
  static bool isJsRule(String rule) {
    final t = rule.trim();
    return t.startsWith('<js') || t.startsWith('@js:');
  }

  /// Legado 多规则分隔符类型；JS/JSONPath 按自身语法执行。
  static String? multiRuleType(String rule) {
    final t = rule.trim();
    if (RuleParser.isJsRule(t) || RuleParser.isJsonPath(t) || RuleParser.isXPathRule(t)) return null;
    for (final separator in ['%%', '||', '&&']) {
      if (RuleParser.splitRule(t, separator).length > 1) return separator;
    }
    return null;
  }
  /// Legado 列表规则前缀（`bookList` 专用）：
  /// - `-规则`：结果倒序
  /// - `+规则`：剥除前缀（Legado 中为去重标记，EasyRead 聚合层恒去重，此处仅剥除）
  /// 返回 `(剥除前缀后的规则, 是否倒序)`。
  static (String, bool) splitListRulePrefix(String rule) {
    var t = rule.trim();
    var reverse = false;
    if (t.startsWith('-')) {
      reverse = true;
      t = t.substring(1).trim();
    } else if (t.startsWith('+')) {
      t = t.substring(1).trim();
    }
    return (t, reverse);
  }

  /// 字段规则是否引用 AllInOne 捕获组或带 `##` 替换后缀。
  static bool needsCaptureGroup(String rule) {
    return rule.contains('##') || RegExp(r'\$\d{1,2}').hasMatch(rule);
  }

  static ReplaceSuffix? replaceSuffixOf(String rule) {
    final index = rule.indexOf('##');
    if (index < 0) return null;
    final baseRule = rule.substring(0, index).trim();
    final parts = rule.substring(index).split('##');
    if (parts.length < 2) return null;
    return ReplaceSuffix(
      baseRule: baseRule,
      pattern: parts[1],
      replacement: parts.length > 2 ? parts[2] : '',
      replaceFirst: parts.length > 3,
    );
  }

  // ---- 解析 ----

  static RuleParts parseRule(String rule) {
    var normalized = rule.trim();
    // Legado `@@`：转义首个 @，避免空首段被当作级联起点
    if (normalized.startsWith('@@')) {
      normalized = normalized.substring(2);
    }
    final segments = RuleParser.splitRule(normalized, '@')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length <= 1) {
      // 纯选择器（单步 CSS，可含级联段）
      return RuleParts(selector: normalized);
    }

    // 最后一段是纯标识符 → 视为属性提取（如 href / src / text / ownText）
    final last = segments.last;
    final isAttr = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$').hasMatch(last);
    if (isAttr) {
      return RuleParts(
        selector: segments.sublist(0, segments.length - 1).join('@'),
        attr: last,
      );
    }
    // 否则整体为级联链（含多段选择器）
    return RuleParts(selector: normalized);
  }

  static int findMatchingParen(String value, int open) {
    var depth = 0;
    for (var i = open; i < value.length; i++) {
      if (value[i] == '(') {
        depth++;
      } else if (value[i] == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// 按分隔符拆分规则，忽略引号与 CSS 属性选择器括号内的分隔符。
  /// 例如 `a[href*="@"]` 不会被拆坏，`class.list@tag.li` 仍按级联拆分。
  static List<String> splitRule(String rule, String separator) {
    if (separator.isEmpty || !rule.contains(separator)) return [rule];
    final parts = <String>[];
    final buffer = StringBuffer();
    var bracketDepth = 0;
    var parenDepth = 0;
    String? quote;

    for (var i = 0; i < rule.length; i++) {
      final ch = rule[i];
      if (quote != null) {
        buffer.write(ch);
        if (ch == r'\' && i + 1 < rule.length) {
          buffer.write(rule[++i]);
        } else if (ch == quote) {
          quote = null;
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        buffer.write(ch);
        continue;
      }
      if (ch == '[') {
        bracketDepth++;
        buffer.write(ch);
        continue;
      }
      if (ch == ']' && bracketDepth > 0) {
        bracketDepth--;
        buffer.write(ch);
        continue;
      }
      if (ch == '(') {
        parenDepth++;
        buffer.write(ch);
        continue;
      }
      if (ch == ')' && parenDepth > 0) {
        parenDepth--;
        buffer.write(ch);
        continue;
      }
      if (bracketDepth == 0 && parenDepth == 0 && rule.startsWith(separator, i)) {
        parts.add(buffer.toString().trim());
        buffer.clear();
        i += separator.length - 1;
        continue;
      }
      buffer.write(ch);
    }
    parts.add(buffer.toString().trim());
    return parts;
  }

  /// 供级联解析复用的 @ 分隔逻辑（与规则解析保持一致）。
  static List<String> splitRuleForCascade(String rule) {
    return RuleParser.splitRule(rule, '@');
  }

/// 解析级联链：`class.list.0@tag.ul.0@tag.li` → 每段 CSS + 可选索引
  static List<CascadeStep> parseCascade(String rule) {
  return RuleParser.splitRuleForCascade(rule)
      .map((segment) => RuleParser.parseStep(segment.trim()))
      .where((s) => s != null)
      .cast<CascadeStep>()
      .toList();
}

static CascadeStep? parseStep(String segment) {
  if (segment.isEmpty) return null;
  var css = segment;
  final indexes = <Object>[];
  var exclude = false;
  var directChildren = false;

  // `[]` 索引写法：tag.li[0,2]、tag.li[!0,2]、tag.li[0:2]、tag.li[-1:0]
  if (css.endsWith(']')) {
    final open = css.lastIndexOf('[');
    if (open > 0) {
      var indexBody = css.substring(open + 1, css.length - 1).trim();
      if (indexBody.startsWith('!')) {
        exclude = true;
        indexBody = indexBody.substring(1).trim();
      }
      final parsed = RuleParser.parseIndexSet(indexBody);
      if (parsed != null) {
        indexes.addAll(parsed);
        css = css.substring(0, open).trim();
      }
    }
  }

  // children 直接子元素前缀：children.0 / children!0:2
  if (!directChildren && css.startsWith('children')) {
    directChildren = true;
    final rest = css.substring('children'.length);
    final childrenIndexes = RuleParser.parseLegacyIndexes(rest);
    if (childrenIndexes != null) {
      indexes.addAll(childrenIndexes.$1);
      exclude = childrenIndexes.$2;
      css = '';
    } else if (rest.isEmpty) {
      css = '';
    } else {
      // children.class.x 等复杂写法暂不识别，退回普通 CSS
      directChildren = false;
    }
  }

  // text.xxx 前缀：匹配自身文本包含 xxx 的元素（Legado getElementsContainingOwnText）
  if (css.startsWith('text.')) {
    final text = css.substring(5);
    if (text.isEmpty) return null;
    return CascadeStep(
      css: '*',
      textQuery: text,
      indexes: indexes,
      exclude: exclude,
    );
  }

  // 旧式索引后缀：tag.li.0 / tag.li.-1 / tag.li.0:2 / tag.li!0
  if (css.isNotEmpty) {
    final indexMatch = RegExp(
      r'^(class\.|id\.|tag\.)(.*?)([.!])(-?\d+(?::-?\d+)*)$',
    ).firstMatch(css);
    if (indexMatch != null) {
      final parsed = RuleParser.parseLegacyIndexes(
        '${indexMatch.group(3)}${indexMatch.group(4)}',
      );
      if (parsed != null) {
        indexes.addAll(parsed.$1);
        exclude = parsed.$2;
        css = '${indexMatch.group(1)}${indexMatch.group(2)}';
      }
    }
  }

  // 索引后缀仅对 Legado 前缀形式生效（class./id./tag.）：
  // 避免误伤纯 CSS 类名（如 .item2 是类名而非索引）
  if (css.isEmpty && !directChildren) return null;

  // Legado 前缀转换
  if (css.startsWith('class.')) {
    css = '.${css.substring(6)}';
  } else if (css.startsWith('id.')) {
    css = '#${css.substring(3)}';
  } else if (css.startsWith('tag.')) {
    css = css.substring(4);
  }
  return CascadeStep(
    css: css,
    indexes: indexes,
    exclude: exclude,
    directChildren: directChildren,
  );
}

/// 解析旧式索引串：`.0` / `.0:2` / `!0` / `!-1:2`。
/// Legado 旧写法中 `:` 为**离散索引分隔符**（AnalyzeByJSoup.kt:283-284：
/// 「阅读原有写法，':'分隔索引」），`tag.div!0:3` = 排除 {0, 3}；
/// 旧写法无步长/区间概念，`-1:10:2` 即三个离散索引（-1 = 倒数第一）。
/// 区间/步长/反向（`[-1:0]` 反向列表）是 `[]` 新语法专属，由
/// [parseIndexSet] 解析，两套语义不可混淆。
  static (List<Object>, bool)? parseLegacyIndexes(String suffix) {
  if (suffix.isEmpty) return null;
  final separator = suffix[0];
  if (separator != '.' && separator != '!') return null;
  final indexBody = suffix.substring(1);
  if (!RegExp(r'^-?\d+(?::-?\d+)*$').hasMatch(indexBody)) return null;
  // 离散索引：负索引转正与越界跳过由 SelectorEngine.expandIndexes 的
  // int 路径处理（与 Legado getElementsSingle 的 indexDefault 消费一致）。
  // 离散 int 不存在 "i += 0" 死循环风险（区间/步长只在 [] 新语法出现，
  // 那里的 step==0 仍由 parseIndexSet 拒绝）。
  final indexes = indexBody.split(':').map(int.parse).toList();
  return (indexes, separator == '!');
}

/// 解析 `[]` 索引集合：数字、`start:end`、`start:end:step`、`-1:0` 反向。
  static List<Object>? parseIndexSet(String body) {
  if (body.isEmpty) return null;
  final result = <Object>[];
  for (final raw in body.split(',')) {
    final item = raw.trim();
    if (item.isEmpty) continue;
    if (RegExp(r'^-?\d+$').hasMatch(item)) {
      result.add(int.parse(item));
      continue;
    }
    final range =
        RegExp(r'^(-?\d+)?:(-?\d+)?(?::(-?\d+))?$').firstMatch(item);
    if (range != null) {
      // Legado 端点省略：start 省略=0、end 省略=len-1（AnalyzeByJSoup
      // startX/endX 可空语义）；end<start 为降序（[-1:0] 反向即此路径）
      final startStr = range.group(1);
      final endStr = range.group(2);
      final start = startStr == null ? 0 : int.parse(startStr);
      final end = endStr == null ? 0 : int.parse(endStr);
      final stepStr = range.group(3);
      final step = stepStr == null ? 1 : int.parse(stepStr);
      // step=0 会在 _expandIndexes 中形成 "i += 0" 死循环冻结主 isolate
      // （[5:0:0] 这类用户可控规则），直接拒绝该索引集（按无索引处理）。
      if (step == 0) return null;
      result.add(IndexRange(
        start: start,
        end: end,
        step: step,
        startOpen: startStr == null,
        endOpen: endStr == null,
      ));
      continue;
    }
    return null;
  }
  return result;
}
}

/// 解析后的规则部件：纯选择器或（选择器 + 属性）。
class RuleParts {
  final String selector;

  /// 级联步骤（selector 为多段 @ 连接时解析）
  final List<CascadeStep>? _cascade;
  final String? attr;

  const RuleParts({required this.selector, this.attr}) : _cascade = null;

  List<CascadeStep>? get cascadeSteps {
    if (_cascade != null) return _cascade;
    final cached = RuleParser._cascadeCache[selector];
    if (cached != null) return cached.isEmpty ? null : cached;
    final steps = RuleParser.parseCascade(selector);
    RuleParser._putCascadeCache(selector, steps);
    return steps.isEmpty ? null : steps;
  }
}

class CascadeStep {
  final String css;
  final List<Object> indexes;
  final bool exclude;
  final bool directChildren;
  final String? textQuery;

  const CascadeStep({
    required this.css,
    this.indexes = const [],
    this.exclude = false,
    this.directChildren = false,
    this.textQuery,
  });
}

class IndexRange {
  final int start;
  final int end;
  final int step;
  final bool reverse;

  /// Legado 端点省略语义：start 省略=0、end 省略=len-1
  /// （展开时按实际列表长度解析）
  final bool startOpen;
  final bool endOpen;

  const IndexRange({
    required this.start,
    required this.end,
    required this.step,
    this.reverse = false,
    this.startOpen = false,
    this.endOpen = false,
  });
}

class ReplaceSuffix {
  final String baseRule;
  final String pattern;
  final String replacement;
  final bool replaceFirst;

  const ReplaceSuffix({
    required this.baseRule,
    required this.pattern,
    required this.replacement,
    required this.replaceFirst,
  });
}
