import 'tag_purifier.dart';
import 'regex_purifier.dart';
import 'layout_purifier.dart';

/// 三阶段净化管线入口
class PurifyPipeline {
  final TagPurifier tagPurifier;
  final RegexPurifier regexPurifier;
  final LayoutPurifier layoutPurifier;

  PurifyPipeline({
    TagPurifier? tagPurifier,
    RegexPurifier? regexPurifier,
    LayoutPurifier? layoutPurifier,
  })  : tagPurifier = tagPurifier ?? TagPurifier(),
        regexPurifier = regexPurifier ?? const RegexPurifier(),
        layoutPurifier = layoutPurifier ?? LayoutPurifier();

  /// 执行完整净化流程（仅 Dart 规则，同步）
  String purify(String html) {
    var result = tagPurifier.purify(html);
    result = regexPurifier.purify(result);
    result = layoutPurifier.purify(result);
    return result;
  }

  /// 执行完整净化流程（Dart 规则 + quickjs JS 规则；无引擎时跳过 JS 规则）。
  /// 任何规则异常都降级返回原文：净化是增强能力，不能因规则问题
  /// 导致章节加载失败。
  Future<String> purifyAsync(String html) async {
    try {
      var result = tagPurifier.purify(html);
      result = await regexPurifier.purifyAsync(result);
      result = layoutPurifier.purify(result);
      return result;
    } catch (_) {
      return html;
    }
  }
}
