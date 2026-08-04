# Phase 2: 阅读器内核 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现自研 Widget 渲染阅读器内核，跑通「搜索 → 进入阅读 → 翻页 → 切换主题 → 退出续读」全链路闭环。

**Architecture:** 阅读器内核按 Feature-first Clean Architecture 组织，核心是 HTML→Node树→分页布局→TextPainter 渲染管线。阅读器数据（进度/缓存）通过 Hive 持久化。

**Tech Stack:** Flutter 3.x, Riverpod, Hive, html 解析库, TextPainter

---

## 文件结构规划

```
lib/features/reader/
├── domain/
│   ├── entities/
│   │   ├── chapter.dart              # 章节实体
│   │   └── reading_progress.dart     # 阅读进度实体
│   ├── repositories/
│   │   └── reader_repository.dart    # 阅读器仓库接口
│   └── usecases/
│       ├── get_chapter_content.dart  # 获取章节内容
│       ├── save_reading_progress.dart# 保存阅读进度
│       └── load_reading_progress.dart# 加载阅读进度
├── data/
│   ├── models/
│   │   ├── chapter_model.dart        # 章节 Hive 模型
│   │   └── reading_progress_model.dart # 进度 Hive 模型
│   └── repositories/
│       └── reader_repository_impl.dart
├── core/
│   ├── parser/
│   │   ├── node_tree.dart            # 解析后的节点树
│   │   └── html_parser.dart          # HTML→Node 树解析
│   ├── pagination/
│   │   └── page_layout.dart          # 分页布局引擎（TextPainter）
│   └── theme/
│       └── reader_theme.dart         # 阅读器主题
└── presentation/
    ├── pages/
    │   └── reader_page.dart          # 阅读页
    ├── widgets/
    │   ├── page_view_widget.dart     # 翻页组件
    │   ├── scroll_view_widget.dart   # 滚动组件
    │   ├── reader_settings_panel.dart# 设置面板
    │   └── progress_bar.dart         # 进度条
    └── providers/
        └── reader_provider.dart      # 阅读器状态管理
```

---

## 任务分解

### Task 13: 阅读器领域层
创建 Chapter / ReadingProgress 实体和 ReaderRepository 接口，含基础测试。

### Task 14: 内容解析引擎
实现 HTML → Node 树解析，支持 p/br/strong/em/h1-h3/img 标签，含测试。

### Task 15: 分页布局引擎
实现 TextPainter 分页：将 Node 树按视口尺寸拆分为多页，支持字号/行距配置，含测试。

### Task 16: 阅读器数据层
Chapter 缓存 + 阅读进度持久化（Hive），含测试。

### Task 17: 阅读器展示层
阅读页（翻页/滚动双模式）、设置面板（字号/行距/主题）、进度条、阅读主题。

### Task 18: 集成与验收
路由接入 /reader/:bookId，从搜索结果进入阅读器，进度保存/恢复验证。

---

## 自检清单

- [ ] 所有文件路径准确
- [ ] 每步含完整代码
- [ ] 无 TBD/TODO
- [ ] 类型定义一致
- [ ] 测试覆盖核心逻辑
