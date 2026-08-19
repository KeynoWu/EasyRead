# Git 提交预案（2026-08-19）

> 工作区现状：历史安全修复（会话开始前 52 文件）+ 本轮 M0 减法 + M1 核心链路 + quickjs 构建修复，
> 全部未提交。以下按逻辑分组提交，每组验证一次（analyze + test）。

## 提交 A：安全与健壮性加固（历史遗留）
- lib/core/network/dio_client.dart（SSRF DNS 重绑定加固）
- lib/core/database/hive_init.dart（密钥降级不覆盖）
- lib/features/search/data/engines/js_rule_executor.dart（Cookie 外泄封堵、请求上限）
- lib/core/purification/purify_pattern_guard.dart（ReDoS 启发式）
- lib/features/settings/domain/usecases/webdav_sync.dart 等（如仍保留）
- 注：本组文件与后续提交有重叠时，用 `git add -p` 按 hunk 拆分。

## 提交 B：收敛为简单小说阅读器（M0 减法）
- 删除的功能/路由/入口/测试/依赖（见 docs/core-first-plan.md 减法清单）
- lib/core/router、main_shell（4 tab）、settings_page、bookshelf_page、book_source_* 页面
- pubspec.yaml/lock（-flutter_tts -archive -xml）

## 提交 C：核心链路修复（M1）
- reader_repository_impl（HTML 兜底移除 + 日志清理 + 空正文报错）
- reader_provider/page_view/scroll_view/reader_settings_panel/reader_page 瘦身
- test/features/reader/chapter_empty_error_test.dart、widget_test 冒烟、integration_test 修复

## 提交 D：quickjs macOS 构建修复
- third_party/quickjs/hook/build.dart（macOS isysroot）

## 一键提交（B/C/D 可合并为一个）
```bash
export PATH=/opt/homebrew/bin:$PATH
cd /Users/wuminxuan/Desktop/test/EasyRead
git add -A
git commit -m "feat: 收敛为简单小说阅读器（减法+核心链路修复+quickjs macOS 构建修复）"
```
提交后验证：`flutter analyze` 0 + `flutter test` 355 全绿 + `flutter test integration_test -d macos` 通过。
