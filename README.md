# 📖 易读 EasyRead

一款**开源免费、纯工具属性**的多源小说阅读器，覆盖 Android、iOS、macOS、Windows、Linux 等 Flutter 支持平台，Android 为主要发布目标。

> 核心逻辑：「工具本体 + 用户自主导入书源」。产品不提供任何书籍内容、不内置书源、不运营内容平台，仅作为内容解析与阅读载体。

## 📦 下载

Android APK 发布包请到 [GitHub Releases](https://github.com/KeynoWu/EasyRead/releases/latest) 下载。

## ✨ 功能特性

### 📚 书架
- 网格 / 列表双视图切换
- 按阅读时间 / 书名 / 加入时间排序
- 分组筛选（正在看 / 已完结 / 囤书 / 自定义）
- 批量管理（多选删除、批量移动分组）
- 本地 TXT / EPUB 导入（自动编码识别、章节解析）

### 🔗 书源管理
- 本地 JSON 文件、网络链接、剪贴板三种导入方式
- 可视化书源编辑器（搜索 / 目录 / 内容规则表单化编辑）
- 书源可用性校验（输入关键词实测解析）
- 订阅链接管理（添加 / 删除 / 单条或批量更新）
- 兼容阅读 3.0 书源规则格式

### 🔍 搜索
- 多源聚合搜索（并发分发 + 按书名分组去重）
- 智能换源（同一本书多源可选，阅读器内一键切换）
- 搜索历史记录（去重、上限 20 条）

### 📖 阅读器
- 翻页 / 滚动双模式 + 仿真翻页动画
- 真实书源内容拉取（目录解析 → 章节正文 → 净化管线）
- 章节目录导航、上一章 / 下一章
- 4 套阅读主题（日间 / 夜间 / 护眼绿 / 羊皮纸）
- 字号 / 行距 / 阅读灯（屏幕亮度）调节
- 书签（当前位置收藏 + 快速跳转）
- 阅读笔记（随手记录想法）
- 章节内关键词搜索（命中页码导航）
- TTS 听书（整章朗读）
- 三阶段内容净化（标签 / 正则 / 排版）
- 阅读进度四重维度持久化 + 断点续读

### ⚙️ 数据与设置
- 本地 JSON 备份 / 恢复
- WebDAV 云同步（跨设备备份与恢复）
- 自定义净化规则管理（正则替换、批量应用）
- 阅读统计（总时长 / 阅读天数 / 最近 7 天柱状图）
- 章节缓存（500 章自动淘汰）+ 后续章节预加载

## 🏗️ 技术架构

```
lib/
├── core/          # 全局基础设施（主题 / 网络 / 路由 / 数据库 / 净化管线）
├── features/      # 功能模块（书架 / 书源 / 搜索 / 阅读器 / 设置 / Shell）
└── main.dart      # 应用入口
```

- **框架**：Flutter 3.44+ (Dart 3.12+)
- **架构**：Feature-first + Clean Architecture
- **状态管理**：Riverpod 3.x
- **本地存储**：Hive（书架 / 书源 / 进度 / 书签 / 笔记 / 缓存）
- **网络层**：Dio + 拦截器链（频率控制 / 自动重试 / UA 轮换）
- **解析引擎**：自研规则引擎（CSS 选择器）+ html 解析
- **渲染引擎**：TextPainter 自研分页布局

## 🚀 构建

```bash
# 安装依赖
flutter pub get

# 运行
flutter run

# 构建 APK
flutter build apk --debug    # Debug 包
flutter build apk --release  # 发布包
```

Release 包输出路径：`build/app/outputs/flutter-apk/app-release.apk`。

> **注意**：Android 构建要求 compileSdk 36（已在 `android/app/build.gradle.kts` 配置）。
>
> Release 签名不再回退到 debug key：本地可通过 `keystore.properties` 或
> `RELEASE_STORE_FILE` / `RELEASE_STORE_PASSWORD` / `RELEASE_KEY_ALIAS` /
> `RELEASE_KEY_PASSWORD` 环境变量配置。GitHub Release CI 必须配置
> `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` /
> `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` secrets，缺失时会直接构建失败。

WebDAV 同步强制要求 HTTPS（仅允许 `localhost`/`127.0.0.1` 使用 HTTP 调试）。
备份文件包含书源 Cookie 等敏感配置，请勿上传到不受信任的位置。

## 📝 测试

```bash
flutter test
```

当前 83 个测试用例覆盖：内容净化管线、书源规则解析、搜索去重与权重、分页布局、TXT/EPUB 导入、备份恢复、网络重试与重定向、导入、阅读进度等核心逻辑。

## 📄 文档

- [产品设计方案](docs/superpowers/specs/2026-08-04-easyread-product-design.md)
- [Phase 1 实施计划](docs/superpowers/plans/2026-08-04-phase1-infrastructure-core.md)
- [Phase 2 实施计划](docs/superpowers/plans/2026-08-04-phase2-reader-core.md)

## ⚖️ 免责声明

本项目为纯工具软件，不提供、不存储、不推荐任何书籍内容。所有内容均由用户自行导入书源获取，请遵守相关法律法规和版权规定。

## 📄 开源许可

[MIT License](LICENSE)
