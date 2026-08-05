# EasyRead 多格式书源兼容 — 续接文档（2026-08-05）

> 重开会话请先读此文件 + 最近 git log。当前 HEAD：`e0d405d`。

## 已交付（全部推送 main，150 测试全过，analyze 0 问题）

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
  - 幂等性边界：两遍执行仅支持纯计算模板规则
- **平台状态**：macOS ✅ 全功能；**iOS 降级**（Flutter native assets 不支持 iOS code assets → 执行器优雅返回 null，模板子集可用）；Android 未验证

## 未完成清单（按优先级）

### 1. Android NDK 交叉编译（hook 适配）【下一优先】
- `third_party/quickjs/hook/build.dart` 目前 iOS 分支用 `xcrun` 交叉编译，**Android 分支缺失**（会失败或产出 x86 宿主库）
- 方案：hook 按 `input.config.code.targetOS == OS.android` 分支，用 NDK clang（环境变量 ANDROID_NDK_HOME/ANDROID_HOME 定位），`CC=$NDK/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android*-clang`，OBJDIR 隔离
- 验证：连 Android 真机 flutter run（需重新 `flutter config --enable-native-assets` 已在）

### 2. setContent 记录-重放（DOM 切换后查询）【中】
- 当前 JsRuleExecutor 对含 `setContent` 的规则返回 null（走模板子集）
- 方案：统一"记录-重放"——第一遍记录 ops（ajax URL / setContent html / get 选择器及当时文档状态），Dart 重放（维护 doc 流：原 html → setContent 更新 → get 在对应 doc 查询），第二遍注入所有结果
- 覆盖：`c=java.ajax(u); java.setContent(c); java.get('sel')` 组合

### 3. 真机/模拟器全链路验证【中】
- iOS 模拟器已部署成功（easyread-ios 进程可重启：`hub start` flutter run -d 5A875797-3788-4821-B24D-263F39E38A17）
- 20MB 书源合集（b778fe6b.json）导入后跑**批量检测**，看可用源提升 + 失败分类
- 搜索真实关键词验证多格式源出结果

### 4. 代码审查收尾【低】
- 阶段 5（quickjs fork + JsRuleExecutor + ajax）尚未做全面审查（阶段 1-4 已审并修 10 项）
- 建议：reviewer 审 JsRuleExecutor 边界（两遍执行幂等、manager 重建、fetcher 注入安全、ajax URL 校验）

## 环境要点
- Flutter SDK：`/Users/wuminxuan/Desktop/my/tool/flutter/bin/flutter`（3.44.8）
- Android 真机：REDMI K90 Pro Max（66ad1898）；iOS 模拟器：iPhone 16 Pro（5A875797...）
- native assets 开关：`flutter config --enable-native-assets`（改动 hook 后需 `rm -rf .dart_tool/hooks_runner/easy_quickjs` 清 dill 缓存）
- 已知陷阱：Dart r-string 里 `\"` 会提前终止字符串；`'$'` 在非 raw 字符串报插值错；测试文件 group 追加需移入 main()

## 测试基线
- `flutter analyze` 0 问题；`flutter test` 150 全过
- 关键测试：js_rule_executor_test（7）、js_rule_executor_ajax_test（4）、json_path_test（12）、rule_engine_cascade_test（8+回归）、js_template_test（10+回归）
