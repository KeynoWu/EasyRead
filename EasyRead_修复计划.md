# EasyRead 完整修复计划（架构收敛 + 体验止血）

> 依据：《EasyRead_架构审视报告.md》的问题清单。原则：不推倒重写，分阶段止损；
> 每个任务给出 涉及文件 / 改动内容 / 验收标准 / 预估 / 风险。每阶段结束统一跑
> `dart analyze lib test`（0 issues）+ `flutter test`（全绿）+ 模拟器/真机冒烟。

---

## 阶段 0：止血 —— 让用户不再看到"像 Web"（预估 3~5 天）

### 0.1 解析失败明确报错，禁止整页 HTML 兜底（P0，最伤体验）
- **问题**：`reader_repository_impl.dart` getChapter 453-456 行，正文提取为空时 `content = html`（整页详情页当正文）；getCatalog 失败被 getChapter 的 `on ChapterLoadException` 静默吞掉 → chapterUrl 空 → 正文=详情页 82KB 网页。
- **改动**：
  - getChapter：移除"整页 HTML 兜底"，提取为空 → 抛 `ChapterLoadException('章节内容为空或解析失败')`，UI 走现有错误态（重试按钮）
  - getChapter 内 getCatalog 失败：不再静默降级，而是抛错并让 UI 提示"目录加载失败，无法定位章节"，提供重试
  - getCatalog：保留"目录失败不阻断正文"的语义，但失败时必须**有 UI 提示**（通过返回错误标记或抛出）
- **文件**：lib/features/reader/data/repositories/reader_repository_impl.dart
- **验收**：天域小说源进入阅读页 → 显示"章节内容为空或解析失败"+ 重试，不再显示整页 HTML
- **风险**：低（改的是失败路径）

### 0.2 移除调试诊断日志
- **改动**：删除本轮加的 `[catalog]` 系列 debugPrint（保留 redactUrl 级别日志）
- **文件**：reader_repository_impl.dart
- **验收**：无 `[catalog]` 输出

### 0.3 统一错误反馈组件
- **改动**：新建 `lib/core/widgets/feedback.dart`：`showAppSnackBar`（统一时长/样式）、`ErrorRetryView`（图标+文案+重试，替换散落的错误 Column）
- **文件**：新增 core/widgets/；替换 reader_page、page_view、book_detail、bookshelf 的散落错误 UI
- **验收**：全 app 错误态视觉一致

### 0.4 已修复项固化（本会话已完成，纳入回归）
- SelectionArea 移除（恢复三区点击）
- 详情页换源面板 ListView 化（修复 3086px 溢出）
- iOS 转场 / 边缘返回 / 回弹 / 触感（保留，做回归用例）

---

## 阶段 1：架构收敛 —— 拆分巨型类、重建分层（预估 3~4 周）

### 1.1 拆分 `js_rule_executor.dart`（2553 行 → 5 个文件）
- **拆分**：
  - `JsRuleExecutor`（编排：超时/回收/两遍执行调度）→ 剩 ~600 行
  - `js_bridge.dart`：java.* 桥定义与注入（get/getString/getElements/ajax/setContent/cookie…）
  - `js_network.dart`：ajax/fetch 安全网络（复用 DioClient，数量上限/超时）
  - `js_crypto.dart`：md5/base64/aes/hmac 等工具
  - `js_record_replay.dart`：记录-重放、setContent 重放
- **文件**：lib/features/search/data/engines/
- **验收**：现有 js_rule_executor_test 全部通过（不动测试语义）；无行为变化
- **风险**：中（引擎是核心资产，需测试兜底；先拆再验证）

### 1.2 拆分 `rule_engine.dart`（1277 行）
- **拆分**：
  - `rule_parser.dart`：规则语法解析（CSS 链/|| /%%/正则/XPATH/JSONPath 识别）
  - `selector_engine.dart`：选择器执行（CSS/正则/XPATH 分发）
  - `rule_engine.dart`：对外 Facade（extractElements/getElementText/extractValue）
- **验收**：rule_engine 相关测试全绿

### 1.3 拆分 `reader_repository_impl.dart`（~1200 行）
- **拆分**：
  - `catalog_parser.dart`：getCatalog + _parseCatalogPage + _parseBookInfo（目录域）
  - `content_extractor.dart`：getChapter 正文部分 + _extractContentPage + _extractNextUrl（正文域）
  - `reader_repository_impl.dart`：保留公共入口 + 缓存 + 进度 + 换源编排，只依赖上面两个
- **验收**：reader_repository_* 测试全绿

### 1.4 拆分 `reader_page.dart`（733 行）
- **拆分**：
  - `reader_tts_controller.dart`：TTS 三态/自动续章/当前页起读逻辑（从 State 抽出）
  - `reader_menu.dart`：顶栏菜单定义（书签/笔记/目录/搜索/换源/保存图片）
  - `reader_page.dart`：仅剩手势分发 + 生命周期编排
- **验收**：阅读页功能行为不变；widget 测试补 2~3 个

### 1.5 provider 接口化
- **改动**：`readerRepositoryProvider`、`bookshelfRepositoryProvider`、`bookSourceRepositoryProvider`、`searchRepositoryProvider` 从 `Provider<具体Impl>` 改为 `Provider<domain接口>`
- **文件**：各 feature 的 presentation/providers/*.dart
- **验收**：测试可用 override 接口替身（现有 _FakeRepo 等继续工作）

### 1.6 domain 层去 Flutter 依赖（旧 P3-1 彻底完成）
- **改动**：backup_restore、import_local_book、import_book_source 中 showDialog/rootBundle 上移 presentation（showPasswordPrompt 已做一半，补齐其余）
- **验收**：`grep -rn "flutter/material" lib/**/domain/` 为空

### 1.7 分层约束
- **改动**：analysis_options.yaml 启用或自定义 lint：domain 禁 import flutter/material、presentation 禁 import 其他 feature 的 presentation provider
- **验收**：CI analyze 强制

---

## 阶段 2：数据层收敛（预估 2~3 周）

### 2.1 统一 DataStore
- **改动**：新建 `lib/core/data/hive_store.dart`：`HiveStore` 封装 openBox/加密盒/明文迁移/适配器注册，所有 service/repository 经它取盒，消灭散落 `Hive.openBox`
- **文件**：lib/core/data/ + 各 data 层
- **验收**：`grep -rn "Hive.openBox" lib/` 仅出现在 hive_store.dart

### 2.2 settings 盒类型化
- **改动**：`reader_settings` 等 `Box<dynamic>` 改为强类型封装（`ReaderSettingsStore`），消除散落的 `box.get('fontSize') as num` 强转
- **文件**：reader_provider、tts_service、phonetic_annotator、auto_refresh 等
- **验收**：无裸 `Box<dynamic>` 业务读取

### 2.3 加密盒探测加固（CRC hack）
- **改动**：`_isPlainBoxOnDisk` 的 CRC 依赖 Hive 帧格式——固化为契约测试 + 升级时回归；或改用"先明文尝试+异常安全"双通道
- **验收**：hive_migration_test 覆盖升级场景

---

## 阶段 3：状态与体验统一（预估 3~4 周）

### 3.1 readerProvider 生命周期与状态精简
- **改动**：`readerProvider` 改 autoDispose（或显式 dispose 时机）；中间态（_pendingProgress/_saveDebounce/_syncChain）收拢进 state 或统一清理；_pageCache 移入独立 cache service
- **验收**：退出阅读页后内存释放（可加诊断）；reader_settings_persistence 测试全绿

### 3.2 设计系统落地
- **改动**：`lib/core/theme/design_tokens.dart`：颜色/间距/圆角/字号 token；替换页面内联硬编码（Colors.blue、Colors.white54、硬编码 padding）
- **验收**：grep 硬编码色值清零；三态（加载/空/错误）组件统一

### 3.3 UI 集成测试补齐
- **改动**：integration_test 增加：阅读器三区点击、末页切章、沉浸式顶栏呼出、换源面板滚动；单元层补 reader_page 手势测试
- **验收**：模拟器 integration_test 全绿（CI 可跑）

### 3.4 体验遗留项（纳入本阶段验收）
- 骨架屏/本地优先（详情页已做，补书架/目录）
- 错误重试统一（0.3）
- 滚动模式/翻页模式进度一致性（已做）

---

## 阶段 4：长期（按需）

### 4.1 规则引擎模块化或收敛兼容承诺
- 若继续支持 Legado 全量规则：1.1/1.2 后按模块维护；否则明确支持子集并文档化
### 4.2 Contract Test
- 书源规则引擎、净化管线、备份恢复加契约测试
### 4.3 CI 强化
- 加覆盖率门禁、integration_test job

---

## 执行顺序与依赖

```
阶段0（3-5天）→ 阶段1.1-1.4 并行（引擎/仓库/页面拆分）→ 阶段1.5-1.7
→ 阶段2（依赖 1.5 接口化）→ 阶段3（依赖 1/2）→ 阶段4
```

每阶段完成标准：`dart analyze lib test` 0 issues + `flutter test` 全绿 + 模拟器冒烟（启动/导航/阅读器/错误路径）。

## 本轮可立即执行的第一批（阶段 0 全部）
0.1 解析失败明确报错（禁止整页兜底）→ 0.2 删诊断日志 → 0.3 统一错误组件 → 验证。
