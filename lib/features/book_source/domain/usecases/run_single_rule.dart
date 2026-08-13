import 'dart:convert';

import '../../../search/data/engines/json_path.dart';
import '../../../search/data/engines/js_rule_executor.dart';
import '../../../search/data/engines/rule_engine.dart';
import '../../../search/data/engines/rule_template.dart';
import '../entities/book_source.dart';

/// 规则类型（规则测试器支持的四类规则）
enum RuleTesterType {
  css('CSS/XPath'),
  jsonPath('JSONPath'),
  js('JS 规则'),
  template('URL 模板');

  final String label;
  const RuleTesterType(this.label);
}

/// 错误分类
enum RuleTesterErrorKind {
  /// 样本解析失败（坏 JSON / 坏 HTML / 样本为空）
  sampleParse('样本解析失败'),

  /// 规则语法错误（空规则 / 无效正则等）
  ruleSyntax('规则语法错误'),

  /// 执行异常（脚本异常 / 超时 / 使用了不支持的能力）
  execution('执行异常'),

  /// 引擎不可用（如 iOS 无 quickjs 原生库 → JS 规则降级）
  unsupported('引擎不可用');

  final String label;
  const RuleTesterErrorKind(this.label);
}

/// 结构化错误信息：分类 + 人类可读描述，供工具页直接展示
class RuleTesterError {
  final RuleTesterErrorKind kind;
  final String message;

  const RuleTesterError(this.kind, this.message);
}

/// 单条规则执行结果（永不抛未捕获异常，错误收敛到 [error]）
class SingleRuleRunResult {
  final RuleTesterType type;

  /// 每项结果列表（CSS 多值 / JSONPath 匹配值 / 展开后 URL / JS 结果）
  final List<String> values;

  /// 结构化错误；null = 执行成功
  final RuleTesterError? error;

  /// 提示信息（如相对路径未提供 baseUrl）
  final String? note;

  /// 耗时（含引擎初始化）
  final Duration elapsed;

  const SingleRuleRunResult({
    required this.type,
    required this.values,
    required this.elapsed,
    this.error,
    this.note,
  });

  bool get isSuccess => error == null;

  /// 匹配数量
  int get count => values.length;
}

/// 单条规则实时调试核心逻辑（供规则测试器页面与单测复用）。
///
/// 入参：样本（HTML 或 JSON）、规则文本、规则类型、可选书源
/// （提供 baseUrl / charset / java 上下文）。
/// 所有执行路径均不抛未捕获异常：样本解析失败、规则语法错误、执行异常
/// 统一收敛为 [SingleRuleRunResult.error]（结构化分类）；JS 无引擎平台
/// （iOS）返回降级说明。
class RunSingleRule {
  const RunSingleRule();

  /// JS 引擎可用性缓存（探测成功后进程内不再重复探测）
  static bool? _jsEngineAvailable;

  /// 执行单条规则。返回结果或结构化错误，绝不抛异常。
  Future<SingleRuleRunResult> run({
    required String sample,
    required String rule,
    required RuleTesterType type,
    BookSource? source,
    String? baseUrl,
    String? charset,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final effectiveBaseUrl = baseUrl ?? source?.bookSourceUrl ?? '';
      final effectiveCharset = charset ?? source?.responseCharset;
      final (values, error, note) = switch (type) {
        RuleTesterType.css => _runCss(sample, rule),
        RuleTesterType.jsonPath => _runJsonPath(sample, rule),
        RuleTesterType.js => await _runJs(
            sample, rule, effectiveBaseUrl, effectiveCharset),
        RuleTesterType.template => _runTemplate(sample, rule, effectiveBaseUrl),
      };
      stopwatch.stop();
      return SingleRuleRunResult(
        type: type,
        values: values,
        error: error,
        note: note,
        elapsed: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return SingleRuleRunResult(
        type: type,
        values: const <String>[],
        error: RuleTesterError(RuleTesterErrorKind.execution, '执行异常：$e'),
        elapsed: stopwatch.elapsed,
      );
    }
  }

  // ---- CSS / XPath ----

  (List<String>, RuleTesterError?, String?) _runCss(
    String sample,
    String rule,
  ) {
    final sampleError = _validateHtmlSample(sample);
    if (sampleError != null) {
      return (
        const <String>[],
        RuleTesterError(RuleTesterErrorKind.sampleParse, sampleError),
        null,
      );
    }
    final syntaxError = _validateCssRuleSyntax(rule);
    if (syntaxError != null) {
      return (
        const <String>[],
        RuleTesterError(RuleTesterErrorKind.ruleSyntax, syntaxError),
        null,
      );
    }
    if (rule.trim().startsWith(':')) {
      // AllInOne 正则链：extractElements 返回捕获组列表
      final items = RuleEngine.extractElements(sample, rule);
      return ([for (final item in items) _stringifyValue(item)], null, null);
    }
    // 选择器/XPath/属性/## 替换后缀：extractTextList 返回每项文本/属性值
    final values = RuleEngine.extractTextList(sample, rule);
    return (values, null, null);
  }

  /// 坏 HTML 预检：空样本 / 含 NUL 字节的二进制垃圾（html 解析器不抛错，
  /// 这类退化输入在解析前拦截并归类为样本解析失败）
  String? _validateHtmlSample(String sample) {
    if (sample.trim().isEmpty) return '样本为空，请输入 HTML 内容';
    if (sample.contains('\u0000')) {
      return '样本包含非法字符（NUL 字节），无法按 HTML 解析';
    }
    return null;
  }

  /// CSS/XPath 规则语法预检：AllInOne `:正则` 链与 `##正则##替换` 后缀
  String? _validateCssRuleSyntax(String rule) {
    final t = rule.trim();
    if (t.isEmpty) return '规则不能为空';
    if (t.startsWith(':')) {
      for (final part in t.substring(1).split('&&')) {
        final pattern = part.trim();
        if (pattern.isEmpty) continue;
        try {
          RegExp(pattern);
        } catch (e) {
          return '正则无效：$pattern（$e）';
        }
      }
    }
    if (t.contains('##')) {
      final suffixParts = t.substring(t.indexOf('##')).split('##');
      if (suffixParts.length >= 2 && suffixParts[1].trim().isNotEmpty) {
        try {
          RegExp(suffixParts[1].trim());
        } catch (e) {
          return '替换正则无效：${suffixParts[1]}（$e）';
        }
      }
    }
    return null;
  }

  // ---- JSONPath ----

  (List<String>, RuleTesterError?, String?) _runJsonPath(
    String sample,
    String rule,
  ) {
    final t = rule.trim();
    if (t.isEmpty) {
      return (
        const <String>[],
        const RuleTesterError(RuleTesterErrorKind.ruleSyntax, '规则不能为空'),
        null,
      );
    }
    if (sample.trim().isEmpty) {
      return (
        const <String>[],
        const RuleTesterError(
            RuleTesterErrorKind.sampleParse, '样本为空，请输入 JSON 内容'),
        null,
      );
    }
    dynamic data;
    try {
      data = jsonDecode(sample);
    } catch (e) {
      return (
        const <String>[],
        RuleTesterError(RuleTesterErrorKind.sampleParse, 'JSON 解析失败：$e'),
        null,
      );
    }
    // JsonPathEngine 对无效路径宽松返回空（不视为错误）；结果字符串化
    final values = JsonPathEngine.instance.query(data, t);
    return ([for (final value in values) _jsonToString(value)], null, null);
  }

  // ---- JS 规则 ----

  Future<(List<String>, RuleTesterError?, String?)> _runJs(
    String sample,
    String rule,
    String baseUrl,
    String? charset,
  ) async {
    final t = rule.trim();
    if (t.isEmpty) {
      return (
        const <String>[],
        const RuleTesterError(RuleTesterErrorKind.ruleSyntax, '规则不能为空'),
        null,
      );
    }
    final available = await _probeJsEngine();
    if (!available) {
      // 无引擎平台（iOS 原生不支持 quickjs 原生资产）→ 降级说明
      return (
        const <String>[],
        const RuleTesterError(
          RuleTesterErrorKind.unsupported,
          '当前平台无 JS 引擎（quickjs 原生库不可用），JS 规则降级不可用',
        ),
        'JS 规则降级：请改用 CSS/XPath、JSONPath 或模板规则',
      );
    }
    final value = await JsRuleExecutor.execute(
      sample,
      t,
      baseUrl: baseUrl,
      charset: charset,
    );
    if (value == null) {
      return (
        const <String>[],
        const RuleTesterError(
          RuleTesterErrorKind.execution,
          'JS 规则执行失败（脚本异常/超时/使用了不支持的能力）',
        ),
        null,
      );
    }
    return ([value], null, null);
  }

  /// 探测 JS 引擎是否可用：能执行 `1+1` 即视为可用。
  /// 复用 JsRuleExecutor 内部初始化（含 5 分钟失败缓存），结果进程内缓存。
  Future<bool> _probeJsEngine() async {
    if (_jsEngineAvailable != null) return _jsEngineAvailable!;
    final result = await JsRuleExecutor.execute('', '@js:1+1');
    _jsEngineAvailable = result != null;
    return _jsEngineAvailable!;
  }

  // ---- URL 模板 ----

  (List<String>, RuleTesterError?, String?) _runTemplate(
    String sample,
    String rule,
    String baseUrl,
  ) {
    final t = rule.trim();
    if (t.isEmpty) {
      return (
        const <String>[],
        const RuleTesterError(RuleTesterErrorKind.ruleSyntax, '规则不能为空'),
        null,
      );
    }
    Map<String, dynamic>? json;
    String? html;
    final trimmedSample = sample.trim();
    if (trimmedSample.isEmpty) {
      // 无样本：仅字面量 / 无变量插值
    } else if (trimmedSample.startsWith('{') || trimmedSample.startsWith('[')) {
      try {
        final decoded = jsonDecode(sample);
        if (decoded is Map<String, dynamic>) {
          json = decoded;
        } else {
          // 数组等非对象样本包装到 {data: ...}，可用 {{$.data}} 引用
          json = {'data': decoded};
        }
      } catch (e) {
        return (
          const <String>[],
          RuleTesterError(RuleTesterErrorKind.sampleParse, 'JSON 解析失败：$e'),
          null,
        );
      }
    } else {
      // 其余按 HTML 样本处理（支持 {{@@规则}} 内联提取）
      html = sample;
    }
    var expanded = RuleTemplate.interpolate(t, json: json, html: html);
    String? note;
    if (expanded.startsWith('/') && baseUrl.isNotEmpty) {
      expanded = _resolveUrl(baseUrl, expanded);
    } else if (expanded.startsWith('/') && baseUrl.isEmpty) {
      note = '展开结果为相对路径，未提供 baseUrl';
    }
    return ([expanded], null, note);
  }

  /// 相对路径基于 baseUrl 展开（baseUrl 末尾补 /）
  String _resolveUrl(String baseUrl, String path) {
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    return '$base${path.substring(1)}';
  }

  // ---- 值字符串化 ----

  String _stringifyValue(dynamic value) {
    if (value is List) {
      // 正则捕获组列表：组间用 | 分隔展示
      return value.map((v) => v?.toString() ?? '').join(' | ');
    }
    return value?.toString() ?? '';
  }

  /// JSON 值转展示文本：标量直出，对象/数组序列化（与 RuleEngine 一致）
  String _jsonToString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString();
    return jsonEncode(value);
  }
}
