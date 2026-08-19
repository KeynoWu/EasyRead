# EasyRead 架构修复方案

| 项目 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 创建日期 | 2026-08-19 |
| 状态 | 待评审（评审通过后按里程碑执行） |
| 关联文档 | 《EasyRead_架构审视报告.md》（诊断过程稿）、docs/CONTINUATION.md |

---

## 1. 背景与目标

### 1.1 背景

EasyRead 是一个功能完整的阅读器 App（搜索/书架/阅读/净化/书源管理/WebDAV 备份/订阅源/TTS/统计，500+ 测试用例），
但在真机与模拟器使用中暴露了明显的体验与工程问题：页面表现"像 Web"（转场生硬、整页 HTML 当正文、白屏等待、交互反复），
且每次改动容易引入回归。经全量代码审视，确认根因不在单一 bug，而在**架构与设计层面**：

- 巨型类职责爆炸（单文件 2553 行的执行器）
- 分层名存实亡（domain 依赖 Flutter、provider 暴露具体实现）
- 状态管理混乱（大状态常驻、可变字段散落）
- 数据层裸奔（散落 openBox、手工适配器、加密探测 hack）
- 静默失败（解析失败无提示、直接降级为原始网页）

### 1.2 目标

1. **止血**：消除用户可见的"像 Web"体验（整页 HTML 当正文、无错误提示、交互失灵）。
2. **收敛**：拆分巨型类、重建分层约束，使改动可预测、可测试。
3. **统一**：数据访问、状态管理、UI 组件（设计系统）形成一致契约。
4. **长期**：规则引擎模块化、契约测试、CI 质量门禁，支撑持续演进。

### 1.3 明确不做什么（范围外）

- **不推倒重写**：保留 500+ 测试、完整功能与 Legado 兼容资产，分阶段重构。
- **不引入新框架/新状态管理库**：继续使用 Riverpod，仅修正用法。
- **不更换数据存储**：继续 Hive，仅收敛访问层。
- **不承诺 Legado 全量规则**：阶段 4 再评估兼容范围。

---

## 2. 现状诊断（问题清单）

### 2.1 架构层

| 编号 | 问题 | 证据 | 严重度 |
|---|---|---|---|
| A-1 | 巨型类职责爆炸 | js_rule_executor.dart 2553 行；rule_engine.dart 1277 行；reader_repository_impl.dart ~1200 行；reader_page.dart 733 行 | 高 |
| A-2 | 分层名存实亡 | domain usecase import flutter/material（backup_restore/import_local_book/import_book_source）；provider 声明具体 Impl 类；feature 间互相 import presentation provider | 高 |
| A-3 | 状态管理混乱 | readerProvider 非 autoDispose，整章内容+分页缓存常驻；_loadSeq/_syncChain/_pageCache/_saveDebounce 游离 Notifier 外；ReaderState 20+ 字段巨型 copyWith | 高 |
| A-4 | 数据层裸奔 | 各 service 自行 Hive.openBox；TypeAdapter 手工位置式编码；加密盒 CRC 帧探测 hack（hive_init.dart _isPlainBoxOnDisk）；settings 大量 Box<dynamic> 裸强转 | 中 |
| A-5 | 规则引擎复杂度失控 | 双引擎（JsTemplateEngine + JsRuleExecutor）+ 2000 行 quickjs FFI；记录-重放/两遍执行/setContent 重放依赖"规则幂等"假设 | 中 |

### 2.2 设计/体验层

| 编号 | 问题 | 证据 | 严重度 |
|---|---|---|---|
| D-1 | 静默失败 | getChapter 正文提取为空 → content=html 整页兜底（reader_repository_impl.dart:453-456）；目录失败被 on ChapterLoadException 静默吞掉 | 高 |
| D-2 | 无设计系统 | 页面内联 Colors.blue/Colors.white54/硬编码尺寸；Material/Cupertino 混搭；三态（加载/空/错误）不统一 | 中 |
| D-3 | 错误处理不统一 | 大量 catch(_) 吞异常；debugPrint 无结构化；无统一错误类型/重试语义 | 中 |
| D-4 | 测试结构畸形 | 500+ 用例集中在引擎/数据层；UI/路由/手势测试几乎为零（widget_test 仅空书架冒烟） | 中 |

### 2.3 保留资产（不重构）

- DioClient 网络层（SSRF/DNS 校验、逐跳重定向敏感头清理、限频、重试）
- quickjs 隔离沙箱（isolate + 超时 + 回收）
- Riverpod autoDispose + family + stream 搜索骨架
- 净化管线分层（pipeline / pattern guard / purifier）
- 引擎层现有测试覆盖

---

## 3. 修复方案（分阶段）

### 阶段 0：止血（预估 3~5 天，优先级最高）

| 任务 | 改动内容 | 涉及文件 | 验收标准 |
|---|---|---|---|
| 0.1 解析失败明确报错 | 移除 getChapter 整页 HTML 兜底；提取为空抛 ChapterLoadException('章节内容为空或解析失败')；目录失败不静默降级，UI 提示+重试 | reader_repository_impl.dart、page_view_widget.dart（错误态已存在） | 天域小说源进入阅读页显示错误+重试，不再显示整页 HTML |
| 0.2 清理诊断日志 | 删除 [catalog] 系列临时 debugPrint | reader_repository_impl.dart | grep 无 [catalog] 输出 |
| 0.3 统一错误组件 | 新增 showAppSnackBar / ErrorRetryView，替换散落错误 UI | 新增 lib/core/widgets/feedback.dart；替换 reader/book_detail/bookshelf | 全 app 错误态视觉一致 |
| 0.4 回归固化 | SelectionArea 移除、换源面板 ListView 化、iOS 转场/边缘返回/回弹/触感纳入回归 | page_view_widget/scroll_view_widget/book_detail_page/app_theme/app_router/app | 对应测试/冒烟通过 |

**阶段 0 完成标准**：dart analyze 0 issues；flutter test 全绿；模拟器冒烟通过（搜索→详情→阅读→错误路径）。

### 阶段 1：架构收敛（预估 3~4 周）

| 任务 | 改动内容 | 涉及文件 | 验收标准 |
|---|---|---|---|
| 1.1 拆分 js_rule_executor（2553 行） | 拆为：JsRuleExecutor（编排）/ js_bridge（java.* 桥）/ js_network（ajax 安全网络）/ js_crypto（加解密工具）/ js_record_replay（记录-重放） | lib/features/search/data/engines/ | js_rule_executor_test 全绿，行为不变 |
| 1.2 拆分 rule_engine（1277 行） | 拆为：rule_parser（语法解析）/ selector_engine（CSS/正则/XPATH 分发）/ rule_engine（Facade） | 同上 | rule_engine 相关测试全绿 |
| 1.3 拆分 reader_repository_impl（~1200 行） | 拆为：catalog_parser（目录域）/ content_extractor（正文域）/ reader_repository_impl（编排+缓存+进度） | lib/features/reader/data/repositories/ | reader_repository_* 测试全绿 |
| 1.4 拆分 reader_page（733 行） | 拆为：reader_tts_controller（TTS 三态/续章）/ reader_menu（菜单定义）/ reader_page（手势+生命周期） | lib/features/reader/presentation/ | 阅读页行为不变；补 2~3 个 widget 测试 |
| 1.5 provider 接口化 | 四个 feature 的 RepositoryProvider 改声明 domain 接口类型 | lib/features/*/presentation/providers/ | 测试可 override 接口替身 |
| 1.6 domain 去 Flutter 依赖 | backup_restore/import_local_book/import_book_source 的 showDialog/rootBundle 上移 presentation | lib/features/*/domain/ | grep domain 目录无 flutter/material |
| 1.7 分层约束 | analysis_options.yaml 自定义 lint（domain 禁 flutter；presentation 禁跨 feature provider import） | analysis_options.yaml | CI analyze 强制通过 |

### 阶段 2：数据层收敛（预估 2~3 周，依赖 1.5）

| 任务 | 改动内容 | 涉及文件 | 验收标准 |
|---|---|---|---|
| 2.1 统一 HiveStore | 新建 HiveStore 封装 openBox/加密盒/明文迁移/适配器；所有 data 层经它取盒 | 新增 lib/core/data/hive_store.dart；各 data 层 | grep "Hive.openBox" 仅存在于 hive_store.dart |
| 2.2 settings 类型化 | reader_settings/tts_settings 等改强类型封装，消除 Box<dynamic> 裸强转 | reader_provider/tts_service/phonetic_annotator/auto_refresh 等 | 无裸 Box<dynamic> 业务读取 |
| 2.3 加密探测加固 | _isPlainBoxOnDisk 的 CRC 帧探测固化为契约测试；评估"先明文尝试+异常安全"双通道 | hive_init.dart、hive_migration_test | 升级场景测试覆盖 |

### 阶段 3：状态与体验统一（预估 3~4 周，依赖 1/2）

| 任务 | 改动内容 | 涉及文件 | 验收标准 |
|---|---|---|---|
| 3.1 阅读器状态生命周期 | readerProvider autoDispose/显式释放；_pendingProgress/_saveDebounce/_syncChain 收拢；_pageCache 移入独立 cache service | reader_provider.dart、book_cache_service.dart | 退出阅读页内存释放；reader_settings_persistence 测试全绿 |
| 3.2 设计系统 | 新建 design_tokens.dart（颜色/间距/圆角/字号）；替换页面内联硬编码；三态组件统一 | 新增 lib/core/theme/design_tokens.dart；各 presentation | grep 硬编码色值清零 |
| 3.3 UI 集成测试 | integration_test 增加：三区点击/末页切章/沉浸顶栏/换源面板滚动；单元补手势测试 | integration_test/、test/features/reader/ | 模拟器 integration_test 全绿 |

### 阶段 4：长期（按需）

| 任务 | 内容 |
|---|---|
| 4.1 规则引擎模块化/收敛兼容 | 按 1.1/1.2 模块维护；或明确支持子集并文档化 |
| 4.2 契约测试 | 规则引擎/净化管线/备份恢复加契约测试 |
| 4.3 CI 强化 | 覆盖率门禁 + integration_test job |

---

## 4. 里程碑与执行顺序

```
M0 阶段0 止血           （3~5 天）      ← 立即执行，无前置依赖
M1 阶段1.1~1.4 拆分      （2~3 周）      ← 可并行，均有测试兜底
M2 阶段1.5~1.7 分层      （1 周）        ← 依赖 M1
M3 阶段2 数据层          （2~3 周）      ← 依赖 M2
M4 阶段3 状态与体验      （3~4 周）      ← 依赖 M3
M5 阶段4 长期            （按需）
```

每个里程碑结束：`dart analyze lib test`（0 issues）+ `flutter test`（全绿）+ 模拟器冒烟（启动/导航/阅读器/错误路径）。

---

## 5. 质量门禁（每任务强制）

1. `dart analyze lib test integration_test`：0 issues
2. `flutter test`：全部通过，且新增/改动路径有测试
3. 模拟器冒烟：启动、底部导航、搜索→详情→阅读、错误路径
4. 拆分类后：原测试不改语义、全绿（行为等价验证）

---

## 6. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 引擎拆分引入行为回归 | 高 | 拆分前先跑全量引擎测试基线；每拆一步即验证；不改规则语义 |
| readerProvider 生命周期改动破坏续读 | 中 | 3.1 保留进度持久化语义；reader_settings_persistence 测试守护 |
| 数据层收敛触碰加密盒迁移 | 中 | 2.3 先行契约测试；明文迁移路径有 hive_migration_test |
| 设计系统替换引入视觉回归 | 低 | 逐页替换+截图对比；token 值对齐现状色值 |
| 重构周期内体验反复 | 中 | 阶段 0 先行止血；每个里程碑模拟器冒烟 |

---

## 7. 执行记录

| 日期 | 里程碑 | 结果 |
|---|---|---|
| （待执行） | M0 阶段0 | - |
