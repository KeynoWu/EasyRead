# EasyRead 多格式书源兼容 — 续接文档（2026-08-05）

> 重开会话请先读此文件 + 最近 git log。

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
- 已知陷阱：Dart r-string 里 `\"` 会提前终止字符串；`'$'` 在非 raw 字符串报插值错；测试文件 group 追加需移入 main()；**Dart 3 switch 非空 case 隐式 break 不 fall-through**（reviewer 曾误报）；**Dart RegExp 不支持 lookbehind**（JS 净化规则需 quickjs）；**JS RegExp 字符串构造必须带 `g` flag 否则 exec 死循环**

## 测试基线
- `flutter analyze` 0 问题；`flutter test` 166 全过
- 关键测试：js_rule_executor_test（9，含泄漏/并发）、js_rule_executor_ajax_test（4）、js_rule_executor_setcontent_test（7，记录-重放）、purify_rules_test（6，内置导入/分流/JS 执行）、json_path_test（12）、rule_engine_cascade_test（8+回归）、js_template_test（10+回归）
