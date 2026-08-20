# EasyRead 多格式书源兼容 — 续接文档（2026-08-05，最新：2026-08-19）

> 重开会话请先读此文件 + 最近 git log。
> **当前主线：docs/core-first-plan.md（v2 核心优先+减法）已取代 docs/refactoring-plan.md。**

## ⚠️ 最新状态（2026-08-19）：产品收敛为「简单小说阅读器」

### 已完成的减法（M0，未提交）
- **删除**：TTS 朗读、图片章节/漫画、RSS 订阅源、阅读统计、WebDAV+本地备份、本地导入 epub/txt、拼音注音、章内搜索、导出书籍、书签/笔记、规则测试器/书源调试页/书源订阅页、发现 tab（导航 5→4）、自动刷新、书单导入导出、source_subscription 数据盒。
- **保留**：书源导入/列表/编辑/登录/批量检测、搜索、详情、阅读（翻页/滚动/进度续读/缓存/换源/净化/排版/亮度/自动换源）、书架、设置（净化规则/清缓存/自动换源）。
- 依赖移除：flutter_tts / archive / xml（保留 pinyin：简繁转换）。
- lib：28945 → 19802 行；测试：503 → 354 用例全绿。

### 已完成的核心链路修复（M1，未提交）
1. 移除整页 HTML 兜底（reader_repository_impl 两处）→ 解析为空抛 ChapterLoadException，阅读页错误+重试。
2. 目录失败可见可重试（chapter_catalog_sheet 已有失败+重试）。
3. [catalog]/[reader] debugPrint 清零。
4. 新增 test/features/reader/chapter_empty_error_test.dart。
5. **修复 quickjs macOS 链接**（third_party/quickjs/hook/build.dart）：macOS 分支补 `xcrun --sdk macosx --show-sdk-path` 的 isysroot（CFLAGS+LDFLAGS），否则 Xcode 新版本 ld 报 `library 'System' not found`，JS 引擎构建失败（此前 macOS 集成测试/构建全挂）。验证：flutter build macos --debug ✅。

### 待办
- [x] M1 冒烟：widget 级 2/2 + macOS 桌面集成测试通过（quickjs 链接修复后）。
- [x] M1-5 真实书源端到端验收（2026-08-20，macOS + iOS 模拟器双平台通过）：
  - 新增 `integration_test/real_source_e2e_test.dart`：真实 URL 导入（aoaostar 71e56d4f.json，22 源）→ 搜索《诡秘之主》命中独步小说网 → 目录 1404 章 → 正文 2777 字符，断言无整页 HTML 兜底（无 html/doctype/head/body 结构）。
  - **验收发现并修复引擎缺口**（rule_engine.dart getElementText）：Legado 裸字段规则 `text`（取元素自身文本）与 `href`（取元素自身属性）此前被当 CSS 标签查询返回 null，导致独步等源目录解析全空。修复：裸标识符命中伪属性（text/ownText/textNodes/html/all）或元素实际存在的属性时取元素值，标签名（a/ul/li 等）仍落回 CSS 路径。新增 4 个单测覆盖。
  - 71e56d4f/XIU2 源集多数已失效（CF 拦截/改版）：独步小说网、天天看小说、阅友小说实测可用（偏好源优先逻辑）。
  - 验证：`flutter analyze` 0 + `flutter test` 361 全绿 + iOS 模拟器端到端通过。
- [x] M2（可选）：拆 js_rule_executor(2553)/rule_engine(1277)/reader_repository_impl(~1250)。（2026-08-20 完成，见 docs/M2_SPLIT_PLAN.md，6 commit 已推送）
- [ ] 提交决策：工作区含历史安全修复(52 文件) + 本次 M0/M1，建议分 2 个 commit。

---

# 历史记录（旧主线，功能仍保留部分已被减法移除）

## 已交付（全部推送 main，166 测试全过，analyze 0 问题）

### 阶段 1-4：规则引擎多格式支持
| 能力 | 状态 | 关键文件 |
|---|---|---|
| CSS 单步 + @attr | ✅ 原有 | `rule_engine.dart` |
| 级联选择器 `class.x.0@tag.ul@tag.li` | ✅ | `rule_engine.dart`（_parseCascade/_parseStep，索引仅前缀形式） |
| POST 搜索 `URL,{json}` + GBK | ✅ | `dio_client.dart`（_send/postForm/postFormHeaders）、`search_repository_impl.dart`（_parseSearchUrl/_resolveUrl） |
| JSONPath `$.data[*]`/`$..x`/`&&` 组合 | ✅ | `json_path.dart` |
| JS 模板子集（java.get 链，无引擎） | ✅ | `js_template.dart` |

### 阶段 5：完整 JS 引擎（quickjs）
- **本地 fork**：`third_party/quickjs`（包名 `easy_quickjs`，path 依赖）
  - 适配 Flutter 3.44 hooks：`hook/build.dart`（native_assets_cli 0.18 API、资产 id `src/lib_quickjs.dart`、iOS 交叉编译 OBJDIR 隔离 + headerpad、`buildAssetTypes` 预判防 iOS 空配置崩溃）
  - **必须先启用**：`flutter config --enable-native-assets`（已执行，新机器需重跑）
  - `forceDispose()` 已加入 JsEngineManager（异常/死循环后强制 kill，规避 quickjs 原生 dispose 断言 SIGABRT）
- **JsRuleExecutor**（`js_rule_executor.dart`）：
  - 完整 JS 执行（字符串/正则/变量/条件），3s 外部超时防死循环，异常/超时后 `_recycle()` 重建 manager
  - java.get 字面量选择器预查询注入；`java.get('url')` → baseUrl
  - **java.ajax 两遍执行**（第一遍收集 URL → Dart 并发请求 → 注入 → 第二遍取结果）；`fetcher` 可注入供测试
  - **java.setContent 记录-重放**：记录遍收集 get/setContent 调用序列（ajax URL 同时收集），Dart 重放 doc 流（原 html → 按序 setContent 切换 → get 在对应 doc 查询），最终遍按调用顺序消费值表。setContent 参数依赖 ajax 结果时（首遍记录为空）先切真实 ajax 桥再重录一遍；`java.get('url')` 特判两遍一致不消费序号
  - 幂等性边界：记录-重放仅支持纯计算模板规则
  - 审查修复：正常路径 `engine.dispose()` 防泄漏（`liveEngineCount` 测试断言）、`_getManager` 链式互斥防双创建、init 失败重置锁允许重试、异常/超时路径跳过 dispose 防挂起（forceDispose 后 dispose 无响应）、**引擎初始化 5s 超时 + 失败 5 分钟短时降级**（无引擎平台不反复挂起）
- **平台状态**：macOS ✅ 全功能；Android ✅（NDK 交叉编译，见下）；**iOS 降级**（Flutter native assets 不支持 iOS code assets → 执行器优雅返回 null，模板子集可用）

### 阶段 6（本次会话）：Android NDK 交叉编译
- `hook/build.dart` 新增 Android 分支：
  - NDK 定位：ANDROID_NDK_HOME/ANDROID_NDK_ROOT → SDK ndk/ 版本最大 → macOS 默认 `~/Library/Android/sdk/ndk`
  - ABI triple 映射（arm64→aarch64 / arm→armv7a / x64→x86_64 / ia32→i686 / riscv64），API level 取 >= targetNdkApi 的最小可用 wrapper 版本（NDK 28 提供 21-35）
  - 经 `CROSS_PREFIX` 让 Makefile 自选 clang；`LIBS=-lm` 覆盖（bionic 无 libdl/libpthread stub）；OBJDIR 按 ABI 隔离（`.obj-android-$arch`）
- `Makefile`：`-Wl,-headerpad_max_install_names`（ld64 专用）抽为 `HEADERPAD`，`CROSS_PREFIX` 非空（交叉编译）时去掉（iOS 走 env CC 不设 CROSS_PREFIX → headerpad 保留）
- `quickjs.c`：`JS_MAKE_VALUE` 定义加 `#ifndef JS_NAN_BOXING` 保护（fork 用指针宽度判 nan boxing，32 位 arm 启用 nan boxing 后该定义引用不存在的 JSValueUnion）
- 验证：`flutter build apk --debug` 产出三 ABI（arm64-v8a/armeabi-v7a/x86_64）的 `libquickjs.so`，符号完整；macOS 原生构建无回归

### 阶段 7（本次会话）：iOS 测试问题修复
- **书源管理批量操作**：筛选栏新增"批量"按钮（进入多选 + 自动全选当前筛选分类），配合底部禁用/启用/删除，一键关闭某类书源
- **搜索按钮**：移除 350ms 防抖自动搜索，改为输入框搜索按钮 / 键盘搜索键 / 回车触发
- **搜索范围过滤**：只搜「开启 + 可搜索 +（未检测或检测可用）」的源（检测不可用的源被排除），搜索数量提示同步过滤
- **阅读器打开报错（多层根因）**：
  1. `ReaderPage.initState` 同步调 `resetForBook` 修改 provider → Riverpod 构建期异常 → 移入 microtask
  2. `ReaderNotifier.build` watch 依赖异步 `purifyPipelineProvider` 的 `readerRepositoryProvider` → 净化加载完成触发 notifier 重建、阅读状态丢失 → 移除 watch（getter 化，方法实时读取）
  3. `resetForBook` 重置 `_viewportReported` 且晚于 postFrame 的 `setViewport` 执行 → 覆盖已上报视口导致延迟分页永不触发（"暂无内容"）→ 不再重置视口（视口是设备属性）
  4. `dispose` 里 `ref.read`（Riverpod 3 unmount 禁止）→ 缓存 notifier 引用
  5. **contentUrl 缺失**：Legado 嵌套结构 `ruleContent.contentUrl` 缺别名（只查顶层）→ `_nestedAliases` 补 `contentUrl` 映射；且 **contentUrl 为空时按 Legado 语义用 detailUrl 提取正文**
  6. **HTTPS 降级重定向被禁**：SF 等站移动版 302 到 `http://` → 允许降级但清除 Cookie/Authorization 敏感头（`_sanitizeRedirectHeaders`）
- 验证：iOS 模拟器 `viewportReported=true` 多本书成功出正文（净化兜底）

### 阶段 8（本次会话）：净化规则内置
- **内置 20 条净化规则**（`assets/purification/rules.json`，来自 legado 净化规则合集）：
  - `PurificationRule` 扩展 `isRegex`/`group`/`order` 字段（兼容旧存储）
  - `ManagePurificationRules.ensureDefaults()`：规则库为空时从 asset 导入（幂等）
  - 净化规则页 initState 先 ensureDefaults 再加载
- **JS 净化执行器**（`core/purification/js_purifier.dart`）：
  - 分流：Dart RegExp 可编译且非 `@js:` 替换 → Dart 执行（5 条）；lookbehind 语法 / `@js:` 模板（15 条）→ quickjs 执行
  - `JsPurifyRule`：pattern 编译为 JS 正则（带 `g` flag，无 g 时 exec 死循环——已修），逐匹配执行 `result=匹配; 脚本`（Legado `@js:` 语义）
  - 引擎初始化 5s 超时 + 失败 5 分钟短时降级；eval 3s 超时防死循环正则
  - `PurifyPipeline.purifyAsync`：整体兜底（净化异常返回原文，不阻塞阅读）
- **平台**：macOS/Android 20 条全支持；iOS 无 quickjs → 跳过 JS 规则，仅 5 条正则生效（不崩溃不挂起）
- 测试：purify_rules_test（6，含导入/幂等/分流/JS 执行/降级）

## 未完成清单（按优先级）

### 1. Android 真机全链路验证【待真机连接】
- adb 无设备时无法执行：`flutter run -d 66ad1898`（REDMI K90 Pro Max）
- 验证点：native assets hook 真机触发、20MB 书源导入 + 批量检测、搜索真实关键词、净化 JS 规则（Android 有引擎）

### 2. iOS 模拟器净化/阅读全链路复验【进行中】
- 净化规则页显示 20 条内置规则
- 阅读无挂起（iOS JS 规则降级路径）

## 环境要点
- Flutter SDK：`/Users/wuminxuan/Desktop/my/tool/flutter/bin/flutter`（3.44.8）
- Android 真机：REDMI K90 Pro Max（66ad1898）；iOS 模拟器：iPhone 16 Pro（5A875797...）
- NDK：`~/Library/Android/sdk/ndk/28.2.13676358`（本机 ANDROID_HOME 环境变量指向 Java home，hook 已按存在性检查跳过，回退到 macOS 默认路径）
- native assets 开关：`flutter config --enable-native-assets`（改动 hook 后需 `rm -rf .dart_tool/hooks_runner/easy_quickjs` 清 dill 缓存）
- 已知陷阱：Dart r-string 里 `\"` 会提前终止字符串；`'$'` 在非 raw 字符串报插值错；测试文件 group 追加需移入 main()；**Dart 3 switch 非空 case 隐式 break 不 fall-through**（reviewer 曾误报）；**Dart 3.12 起 RegExp 支持 lookbehind**（旧文档"不支持"已过时，JS 净化仍走 quickjs 保证语义一致）；**JS RegExp 字符串构造必须带 `g` flag 否则 exec 死循环**

## 测试基线
- `flutter analyze` 0 问题；`flutter test` 166 全过
- 关键测试：js_rule_executor_test（9，含泄漏/并发）、js_rule_executor_ajax_test（4）、js_rule_executor_setcontent_test（7，记录-重放）、purify_rules_test（6，内置导入/分流/JS 执行）、json_path_test（12）、rule_engine_cascade_test（8+回归）、js_template_test（10+回归）

## 阶段 9（2026-08-07）：全面审查 + 缺陷修复

### 审查基线
- `flutter analyze` 0 问题；`flutter test` 302 全过（修复后 318 全过）
- 覆盖 core/network、purification、book_source、search、reader、bookshelf、settings 全模块

### 已修复缺陷

**P1 数据闭环**
- 书架续读丢失书源 `@put:` 变量：`BookDetailService` 新增 `variablesJson` 持久化，
  书架打开阅读器/刷新详情/自动更新全部透传变量（`BookDetail.decodeVariables`）
- 排版/主题/阅读模式不持久化：`reader_settings` 盒新增 fontSize/lineHeight/fontFamily/
  theme/readingMode，`ReaderNotifier.loadPersistedSettings()` 进入阅读页时恢复，
  修改时异步落盘（新增 reader_settings_persistence_test）
- TTS 朗读 HTML 标签/异常卡死：`TtsService.toPlainText()` 转纯文本朗读；
  ReaderPage 朗读失败 try/finally 复位播放状态（新增 tts_service_test）

**P2 行为/安全**
- 聚合搜索重复发 `finished:true`：改为收尾只发一次；`SearchBooks.mergeResults`
  按 sourceId 去重替代源（新增单次 finished + 去重测试）
- 章节图片只显示占位：`ReaderRepositoryImpl.resolveImageUrls` 把相对 src 解析为
  绝对 URL，翻页/滚动视图用 `Image.network` 真实渲染（新增 image_url_resolve_test）
- 翻页模式页内可滚动与 PageView 手势冲突：移除页内 `SingleChildScrollView`
- 删除书籍残留书签/笔记：`BookmarkService/NoteService.removeAllForBook`，
  书架批量删除时同步清理（services_test 补断言）
- WebDAV 恢复无确认：下载前增加覆盖确认弹窗，与本地恢复一致
- 净化规则"删空重启复活"：`ensureDefaults` 改用 `__defaults_imported` 导入标记
  （新增删空不复活测试）
- 登录 Cookie 明文存储：`CookieJarService` 改用 AES 加密盒（复用
  `openSensitiveBox` 明文迁移），备份/恢复同步走加密打开
- JS `java.ajax/post/head` 一次性全量并发：限制并发上限 4
- 调试搜索不走登录流程：`debugSearch` 复用 `_ensureLoginHeaders/_applyLoginCheck`

**P3 细节**
- 阅读设置面板小屏不可滚动：`ConstrainedBox(0.8h) + SingleChildScrollView`
- 阅读器顶栏长标题溢出：标题 `Flexible + ellipsis`
- 章节缓存命中不刷 `cachedAt`：限频（1h）刷新，避免 LRU 误淘汰热章节
- 章节内搜索文案 0-based 误导：改为 `第 x/N 处`
- 换源面板恒显示"当前书源"：改为读取真实书源名
- 规则/书源编辑/导入对话框 `TextEditingController` 泄漏：try/finally 释放
- 书签/笔记统一管理页只显示 base64 ID：联动书架显示书名
- `widget_test.dart` 空壳：改为真实书架页 smoke 测试（pump EasyReadApp）

### 仍未处理（低风险/需真机）
- `Navigator.push` 与 go_router 混用（详情页换源/设置/书源页）：路由栈不受
  GoRouter 管理，建议后续统一迁移
- 备份 JSON 明文包含 Cookie 登录态：加密盒已加固本地存储，导出文件仍有提示，
  后续可做可选加密导出
- Android/iOS 真机全链路验证依赖外部设备（见未完成清单）