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
        regexPurifier = regexPurifier ?? RegexPurifier(),
        layoutPurifier = layoutPurifier ?? LayoutPurifier();

  /// 执行完整净化流程
  String purify(String html) {
    var result = tagPurifier.purify(html);
    result = regexPurifier.purify(result);
    result = layoutPurifier.purify(result);
    return result;
  }
}
