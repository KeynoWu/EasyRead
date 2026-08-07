import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../domain/usecases/manage_purification_rules.dart';

/// 用户配置的净化规则 → 净化管线。
/// 规则存放在 Hive（异步读取），加载完成后通过 [PurifyPipeline] 注入阅读仓库。
/// 首次启动时若规则库为空，先导入内置默认规则集。
final purifyPipelineProvider = FutureProvider<PurifyPipeline>((ref) async {
  final manager = ManagePurificationRules();
  await manager.ensureDefaults();
  final purifier = await manager.buildPurifier();
  final titlePurifier = await manager.buildTitlePurifier();
  return PurifyPipeline(
    regexPurifier: purifier,
    titlePurifier: titlePurifier,
  );
});
