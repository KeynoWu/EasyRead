import 'tag_purifier.dart';
import 'regex_purifier.dart';
import 'layout_purifier.dart';

/// 三阶段净化管线入口。
///
/// 规则超时会话级禁用:超时规则 id 进入禁用集,本管线实例内不再执行;
/// [buildPurifyPipeline] 的 [onRuleDisabled] 通知调用方持久化
/// (下次冷启动/规则刷新自然不含该规则,Legado 语义)。
class PurifyPipeline {
  final TagPurifier tagPurifier;
  final RegexPurifier regexPurifier;
  final RegexPurifier titlePurifier;
  final LayoutPurifier layoutPurifier;

  /// 会话级禁用的规则 id(超时自动禁用)
  final Set<String> _disabledRuleIds;

  PurifyPipeline({
    TagPurifier? tagPurifier,
    RegexPurifier? regexPurifier,
    RegexPurifier? titlePurifier,
    LayoutPurifier? layoutPurifier,
    Set<String>? disabledRuleIds,
  })  : tagPurifier = tagPurifier ?? TagPurifier(),
        regexPurifier = regexPurifier ?? const RegexPurifier(),
        titlePurifier = titlePurifier ?? const RegexPurifier(),
        layoutPurifier = layoutPurifier ?? LayoutPurifier(),
        _disabledRuleIds = disabledRuleIds ?? {};

  /// 当前会话禁用后的执行器(超时规则不再执行)
  RegexPurifier get _activeContentPurifier =>
      regexPurifier.withoutRules(_disabledRuleIds);
  RegexPurifier get _activeTitlePurifier =>
      titlePurifier.withoutRules(_disabledRuleIds);

  /// 执行完整净化流程(Dart 规则 + quickjs JS 规则;无引擎时跳过 JS 规则)。
  /// 任何规则异常都降级返回原文:净化是增强能力,不能因规则问题
  /// 导致章节加载失败。
  Future<String> purifyAsync(
    String html, {
    String? bookName,
    String? sourceName,
    String? sourceUrl,
  }) async {
    try {
      var result = tagPurifier.purify(html);
      result = await _activeContentPurifier
          .scopedFor(
            bookName: bookName,
            sourceName: sourceName,
            sourceUrl: sourceUrl,
          )
          .purifyAsync(result);
      result = layoutPurifier.purify(result);
      return result;
    } catch (_) {
      return html;
    }
  }

  /// 净化章节标题(仅应用标题作用域规则)。
  Future<String> purifyTitle(
    String title, {
    String? bookName,
    String? sourceName,
    String? sourceUrl,
  }) async {
    try {
      return await _activeTitlePurifier
          .scopedFor(
            bookName: bookName,
            sourceName: sourceName,
            sourceUrl: sourceUrl,
          )
          .purifyAsync(title);
    } catch (_) {
      return title;
    }
  }
}

/// 构造带超时自动禁用接线的管线:
/// 任一规则执行超时 → id 加入会话禁用集(本实例内不再执行)
/// → [onRuleDisabled] 通知持久化(同一规则只通知一次)。
PurifyPipeline buildPurifyPipeline({
  TagPurifier? tagPurifier,
  RegexPurifier? regexPurifier,
  RegexPurifier? titlePurifier,
  LayoutPurifier? layoutPurifier,
  void Function(String ruleId)? onRuleDisabled,
}) {
  final disabled = <String>{};
  final notified = <String>{};
  void handleTimeout(String ruleId) {
    if (ruleId.isEmpty) return;
    disabled.add(ruleId);
    if (notified.add(ruleId)) onRuleDisabled?.call(ruleId);
  }

  RegexPurifier? wire(RegexPurifier? p) {
    if (p == null) return null;
    return RegexPurifier(
      rules: p.rules,
      jsRules: p.jsRules,
      onRuleTimeout: (rule) => handleTimeout(rule.id),
      onJsRuleTimeout: (rule) => handleTimeout(rule.id),
    );
  }

  return PurifyPipeline(
    tagPurifier: tagPurifier,
    regexPurifier: wire(regexPurifier),
    titlePurifier: wire(titlePurifier),
    layoutPurifier: layoutPurifier,
    disabledRuleIds: disabled,
  );
}
