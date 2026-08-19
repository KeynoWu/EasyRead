# EasyRead 架构与设计审视报告（根源级）

> 立场：抛开既有修复与小 bug，从架构/设计/工程本质重新审视。诚实为主：烂的地方直接说烂，但也不为了迎合而全盘否定——哪些值得保留、哪些该推倒，分清楚。
> 证据：基于全量代码阅读（lib 全部文件、引擎层、数据层、网络层、UI 层、测试层）+ 真机/模拟器运行观察。

## 一、总体判断

**这是一个"功能驱动、逐步堆叠"的产物：功能全、能跑、但架构和工程质量停留在"能做出来"的水平，远未达到"做得好"。**

核心症状不是某一个 bug，而是**每个层面都在为前一个层面的欠债买单**：
- 规则引擎为了兼容 Legado 书源生态被推到极致复杂（7700+ 行），
- 数据层却裸用 Hive、手工适配器、无统一仓储，
- 状态管理把大状态常驻内存、可变字段散落 Notifier 外，
- UI 层没有设计系统、交互反复变化、错误处理静默吞异常。

用户体感"太烂"是真实的，且与架构根源直接对应（详见第四节）。

## 二、架构层面的根本问题

### 2.1 巨型类 / 职责爆炸（最严重）

| 文件 | 行数 | 塞了什么 |
|---|---|---|
| lib/features/search/data/engines/js_rule_executor.dart | **2553** | JS 桥、ajax 两遍执行、cookie 桥、加解密、记录-重放、setContent 重放、模板求值 |
| lib/features/search/data/engines/rule_engine.dart | **1277** | CSS/正则/XPATH/JSONPath/JS 规则、多规则合并、字段提取 |
| lib/features/reader/data/repositories/reader_repository_impl.dart | ~1200 | 目录/正文/详情/换源/缓存/净化/登录检查/变量 |
| lib/features/reader/presentation/pages/reader_page.dart | 733 | TTS、书签、笔记、换源、自动换源、亮度、阅读统计、手势 |

这不是"分个层"能解决的——是**每个类同时承担了数据获取、解析、缓存、安全、UI 编排**。任何一个类的修改都会波及无关功能。这是项目"越改越乱、每修一个 bug 引入两个"的根本原因。

### 2.2 分层名存实亡

- domain 层 usecase 直接 import Flutter/material、showDialog、rootBundle（旧报告 P3-1）
- provider 声明具体实现类（`Provider<ReaderRepositoryImpl>`）而非接口——无法注入替身、无法测试
- feature 间互相 import presentation provider（reader_provider import bookshelf_provider、book_source_provider）
- repository 接口大多只是壳，实现内部直接 `new` 依赖（`Dio()`、`Hive.openBox`）

结论：所谓 Clean Architecture 的"domain/data/presentation"只是**目录摆设**，依赖方向从未真正建立。

### 2.3 状态管理混乱

- `readerProvider` 非 autoDispose：整章正文 + 分页缓存 + 目录常驻内存，退出阅读页也不释放
- `ReaderNotifier` 外游离大量可变字段：`_loadSeq`、`_syncChain`、`_pageCache`、`_saveDebounce`、`_chineseMode`、`_settingsScope`——状态来源分散，靠手动约定同步
- `ReaderState` 是一个 20+ 字段的巨型 copyWith 类，每次翻页整体重建
- 净化管线→仓库用 `ref.listen` 手动推状态（`setPipeline`），绕开 Riverpod 的数据流

### 2.4 数据层裸奔

- 每个 service/repository 自己 `Hive.openBox`，无统一数据访问层
- TypeAdapter 手工位置式编码（虽加了版本字节，仍是脆弱的）
- 加密盒用 **CRC 帧探测 hack** 判断明文/加密（依赖 Hive 内部帧格式，升级即碎）
- settings 盒大量 `Box<dynamic>` 裸存取，无类型安全

### 2.5 规则引擎：复杂度失控（为兼容而背的债）

- 为了兼容 Legado 书源规则，实现了**双引擎**（阶段 4 模板子集 + 阶段 5 完整 JS）+ 2000 行 quickjs FFI 胶水
- **记录-重放 / 两遍执行 / setContent 重放**：靠"规则幂等"假设，任何副作用规则都会算错
- 2553 行的执行器同时处理网络、加解密、DOM 重放、超时、回收——任何一处崩溃都可能拖垮整条规则链
- 这个引擎是项目里**最贵也最脆弱**的资产：测试覆盖最多的恰恰是它（因为最复杂），但正因为它复杂，才需要重构成小模块

### 2.6 网络层是少数亮点

`DioClient`：SSRF 字面量+DNS 校验、逐跳重定向敏感头清理、限频、重试、UA——这部分写得认真，是项目里质量最高的模块之一。**不要动它**（除非重构出统一出站策略）。

## 三、设计层面的问题

### 3.1 "静默失败"是体验烂的最大设计缺陷

- 目录解析失败 → 静默退化成"详情页整页 HTML 当正文"（真机复现：天域小说源，0 章目录 → 正文=82KB 网页）
- 大量 `catch (_) {}` 吞异常，用户得不到任何提示
- 用户看到的"像 web"、白屏、无反应，本质是**解析失败无感知、无降级提示**

### 3.2 无设计系统

- 颜色/间距/圆角/组件无 token 统一：`AppColors` 是常量堆，但各页面大量内联 `Colors.blue`、`Colors.white54`、硬编码尺寸
- Material/Cupertino 混搭（本轮刚修了转场，但控件层仍混）
- 交互没有一致契约：同样的操作在不同页面手势不同（长按/点击/菜单）

### 3.3 错误处理与日志

- `debugPrint` 无结构化、无级别、无上下文
- 异常多数被吞，少数抛给 UI 显示原始文本
- 没有统一错误类型/错误 UI/重试语义

### 3.4 测试结构畸形

- 62 个测试文件 500+ 用例，但**集中在引擎/数据层**（因为最复杂）
- UI/交互/路由测试几乎为零（widget_test 只有空书架冒烟）
- 讽刺：最复杂的部分测得多，最影响体验的部分没测——所以每次 UX 改动都引入回归（本轮 SelectionArea 拦截点击就是例证）

## 四、"像 Web / 体验烂"与架构的对应关系

| 用户体感 | 架构根源 |
|---|---|
| 搜索/详情/正文显示整页 HTML"像 Web" | 规则解析失败静默降级，无感知提示（3.1） |
| 转场生硬、像 Android/Web | 无平台转场设计，Material 默认（本轮已修转场动画） |
| 白屏/转圈等待 | 全屏 FutureBuilder+转圈模式，无骨架屏/本地优先（部分已修） |
| 交互反复、点不动、无反馈 | 巨型 State 里手势/状态耦合，无交互契约（2.1/2.3） |
| 越改越乱、修一个坏两个 | 巨型类 + 无分层约束 + UI 无测试（2.1/3.4） |

## 五、值得保留的部分（不要推倒）

- **DioClient 网络层**（SSRF/重定向/限频/重试）——认真，保留
- **Riverpod 使用骨架**（autoDispose family stream 搜索、cancel token）——方向对
- **净化管线分层**（pipeline/pattern guard/purifier）——合理
- **quickjs 隔离沙箱**（isolate + 超时 + 回收）——必要且正确
- **对引擎的测试覆盖**——务实（虽然畸形，但比没有强）

## 六、重构路线图（不是推倒重写，是分阶段止损）

**阶段 0：止血（1~2 周，立刻可做）**
- 解析失败明确报错：目录/正文失败给出可读提示 + 重试，**禁止整页 HTML 兜底**
- 移除/重做不稳定交互（SelectionArea 已回退）
- 统一 SnackBar/错误组件

**阶段 1：架构收敛（2~4 周）**
- 拆分巨型类：js_rule_executor（引擎/桥/安全/网络 四拆）、reader_repository（目录/正文/缓存/详情 四拆）、reader_page（TTS/书签/手势 拆出）
- provider 全部声明接口类型；domain 层去 Flutter 依赖（旧 P3-1 彻底做）
- 引入分层 lint（禁止 domain import flutter/presentation）

**阶段 2：数据层（2~3 周）**
- 统一 DataStore：openBox/适配器/迁移集中管理，消灭散落 openBox
- settings 盒类型化（不用 Box<dynamic>）

**阶段 3：状态与体验（3~4 周）**
- readerProvider autoDispose + 状态模型精简（中间态收拢）
- 设计系统：颜色/间距/组件 token，统一页面模式（骨架屏/错误态/空态三态规范）
- UI 集成测试补起来（导航/阅读器手势/错误路径）

**阶段 4：长期**
- 规则引擎模块化重构（或明确降低 Legado 兼容承诺，收敛复杂度）
- 全量 contract test

## 七、给用户的直白结论

1. 你的直觉是对的：这个项目**架构层面确实烂**——巨型类、分层名存实亡、状态混乱、数据层裸奔，这些不是错觉。
2. 但它**不是没有救**：烂的部分集中在"功能堆叠"层（引擎/仓库/State），而网络层、沙箱、Riverpod 骨架是可保留的地基。
3. **不建议推倒重写**：500+ 测试、完整功能、Legado 兼容资产都在，重写会丢掉这些且周期极长。更现实的是**分阶段止损**：先让用户不再看到整页 HTML 和静默失败（止血），再逐层收敛架构。
4. 如果你对"和 web 一样"的体验零容忍，阶段 0 的止血 + 阶段 3 的体验统一，是最能感知到变化的路径。
