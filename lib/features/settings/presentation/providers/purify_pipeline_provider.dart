import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../domain/usecases/manage_purification_rules.dart';

/// 净化规则管理器:可由测试 override 注入替身(避免硬 new 无法替换依赖)。
final managePurificationRulesProvider =
    Provider<ManagePurificationRules>((ref) => ManagePurificationRules());

/// 用户配置的净化规则 -> 净化管线。
/// 规则存放在 Hive(异步读取),加载完成后通过 [PurifyPipeline] 注入阅读仓库。
/// 首次启动时若规则库为空,先导入内置默认规则集。
///
/// 超时自动禁用(Legado 语义):规则执行超时 → enabled=false 持久化到 Hive
/// → 下次冷启动/规则刷新自然不含该规则。
final purifyPipelineProvider = FutureProvider<PurifyPipeline>((ref) async {
  final manager = ref.watch(managePurificationRulesProvider);
  await manager.ensureDefaults();
  final purifier = await manager.buildPurifier();
  final titlePurifier = await manager.buildTitlePurifier();
  return buildPurifyPipeline(
    regexPurifier: purifier,
    titlePurifier: titlePurifier,
    onRuleDisabled: (ruleId) {
      // 持久化在异步回调中完成;管线实例本身已持有全部规则,
      // 无需 invalidate 本 provider(阅读中重建会抖动),
      // Hive 写入即持久禁用:下次冷启动/规则刷新自然排除。
      unawaited(manager.disableRule(ruleId));
    },
  );
});
