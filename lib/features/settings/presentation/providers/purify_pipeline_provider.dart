import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../../../core/purification/regex_purifier.dart';
import '../../domain/usecases/manage_purification_rules.dart';

/// 用户配置的净化规则 → 净化管线。
/// 规则存放在 Hive（异步读取），加载完成后通过 [PurifyPipeline] 注入阅读仓库。
final purifyPipelineProvider = FutureProvider<PurifyPipeline>((ref) async {
  final rules = await ManagePurificationRules().getAll();
  final enabled = <PurifyRule>[];
  for (final rule in rules) {
    if (!rule.enabled || rule.pattern.isEmpty) continue;
    try {
      RegExp(rule.pattern); // 校验正则合法性，非法规则跳过避免运行期崩溃
      enabled.add(PurifyRule(pattern: rule.pattern, replacement: rule.replacement));
    } catch (_) {
      // 忽略非法正则
    }
  }
  return PurifyPipeline(regexPurifier: RegexPurifier(rules: enabled));
});
