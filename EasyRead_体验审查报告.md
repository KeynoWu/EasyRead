# EasyRead 体验（UX）审查报告 — 重点：阅读体验

> 审查范围：以阅读器（reader feature）为核心，辐射书架/详情/搜索/设置等入口页。
> 审查方式：逐文件阅读 lib/features/reader 全部表现层代码 + 周边页面，重点核对交互路径与状态流转。
> 与本仓库既有的《EasyRead_审查汇总报告.md》（架构/安全/引擎维度，P0-P3 已基本修复）互补，本报告聚焦**用户可感知的体验问题**，不含数据安全/健壮性内容。
> 严重度：P1=核心阅读流断裂/高频率误触；P2=明显体验缺陷；P3=增强项。

## 一、总体结论

功能骨架完整、设置项丰富（字号/行距/段距/字重/衬线/主题/翻页动画/简繁/朗读/亮度/设置范围），进度保存、分页缓存、章节预加载、自动换源等数据层做得相当扎实。但**阅读交互层明显落后于主流阅读器（微信读书/Legado/掌阅）**，最突出的三处是：

1. **翻页模式没有"点击翻页"，整页点击只开关设置面板** —— 阅读核心手势缺失；
2. **翻页模式读到本章末页后无法自然进入下一章** —— 阅读流断裂，必须开菜单手动切章；
3. **滚动 ↔ 翻页模式切换丢失阅读位置** —— 模式切换回到章节开头或陈旧页码。

另有顶栏常驻破坏沉浸感、滚动模式无进度指示、TTS 从章首朗读且无暂停/续章、正文不可选中复制、书签/笔记入口深藏二级菜单等 20+ 项体验问题，详见下文。

## 二、阅读器核心体验（P1）

### UX-01　翻页模式无"点击翻页"，整页点击仅切换设置面板（P1）
- 文件: lib/features/reader/presentation/widgets/page_view_widget.dart:149-150；scroll_view_widget.dart:119-120
- 现状: 正文区整体包一层 `GestureDetector(onTap: notifier.toggleSettings)`，点击屏幕**任意位置**都只是开关底部设置面板。翻页只能靠左右滑动。
- 影响: ① 用户点击正文想翻页会弹设置面板，误触率高，阅读被打断；② 主流阅读器均为"点右侧翻下一页 / 点左侧翻上一页 / 点中间呼出菜单"，本实现与之相反，学习与迁移成本高；③ 设置面板开关被绑在阅读区点击上，无法单独呼出工具栏。
- 建议: 按屏幕三区（左 1/3、右 1/3、中 1/3）划分手势：左右点击调 prevPage/nextPage，中间点击切换工具栏（顶栏+底部栏）。设置面板仅由工具栏按钮控制；保留滑动翻页。

### UX-02　翻页模式本章末页无法自然进入下一章（P1）
- 文件: lib/features/reader/presentation/widgets/page_view_widget.dart:151-162（PageView itemCount=本章页数，onPageChanged 仅 jumpToPage）
- 现状: 末页再向右滑动无响应（PageView 已到边界），无任何"下一章"入口提示（仅双栏末屏右栏有纯文本"本章完"占位，单栏没有）。
- 影响: 阅读流硬中断，用户须经"更多→下一章"或目录手动切章，翻页节奏被破坏。
- 建议: ① 末页继续右滑（onPageChanged 到末页 + 继续滑动）触发 nextChapter；② 或末页底部显示"本章完 · 点击进入下一章"按钮；③ 翻到新章时 PageView 重建到第 0 页（当前 _ensureController 已处理页码同步，需补过渡动画避免生硬跳变）。

### UX-03　滚动 ↔ 翻页模式切换丢失阅读位置（P1）
- 文件: lib/features/reader/presentation/providers/reader_provider.dart:809-823（switchMode）
- 现状: 两种模式进度维度分离——滚动模式只更新 `scrollOffset`（pageIndex 保持旧值/0），翻页模式只更新 `pageIndex`（scrollOffset 保持旧值）。切回翻页时 `_alignPage(state.progress?.pageIndex ?? 0, ...)`，因滚动期间 pageIndex 未更新，会回到滚动前的陈旧页码甚至章节开头；切到滚动时 currentPage 被置 0，也不按 pageIndex 换算 scrollOffset。
- 影响: 用户在设置面板切换"翻页/滚动"后位置跳变，需重新找位置，核心体验受损。
- 建议: 切换时按比例互算——page→scroll 时 `scrollOffset = pageIndex/pages.length`（滚动视图恢复用）；scroll→page 时 `pageIndex = (scrollOffset*pages.length).round()`，并用 chapterIndex 校验归属章节。

## 三、阅读器核心体验（P2）

### UX-04　阅读页顶栏常驻，非沉浸式阅读（P2）
- 文件: lib/features/reader/presentation/pages/reader_page.dart:532-694
- 现状: 章节标题 + 返回/TTS/设置/更多 按钮行**永远显示**在顶部；底部进度条/章节导航常驻。
- 影响: 纵向空间被占约 100px+；长时间阅读时顶栏文字与按钮形成视觉干扰，与主流"点击呼出、自动隐藏"的沉浸设计差距大。
- 建议: 顶栏默认隐藏（仅状态栏区域留白），点击中间呼出菜单时一并显示顶栏+底部栏；底部进度条可保留（信息密度低）。

### UX-05　滚动模式无阅读进度指示（P2）
- 文件: lib/features/reader/presentation/widgets/scroll_view_widget.dart:133-162
- 现状: 滚动模式底部是"上一章 | 标题 | 下一章"，无 0~100% 进度；翻页模式底部有 X/Y 页码 + 进度条。
- 影响: 滚动阅读时无法感知本章/全书位置，与翻页模式体验不一致。
- 建议: 底部加归一化进度条（`state.progress.scrollOffset` 已有），显示本章百分比。

### UX-06　章节加载仅整屏转圈，无缓存优先/骨架过渡（P2）
- 文件: page_view_widget.dart:83-85；scroll_view_widget.dart:74-76；reader_provider.dart:307
- 现状: 切章时整个正文区替换为 CircularProgressIndicator；即使 `preloadChapters` 已缓存下一章，UI 仍先闪一次转圈再渲染。
- 影响: 网络慢时白屏转圈数秒；快速连翻章时反复闪圈，跳动感强。
- 建议: 加载中保留上一章内容叠加轻量 loading 遮罩（或命中缓存时直接先渲染）；章节切换用 AnimatedSwitcher 做淡入过渡。

### UX-07　TTS 朗读体验单一：从章首开始、无暂停、读完不续章（P2）
- 文件: lib/features/reader/data/services/tts_service.dart；reader_page.dart:475-495
- 现状: ① `_toggleTts` 固定朗读整章从开头（`toPlainText(content)`），不从当前页开始；② 只有播放/停止两个状态，无暂停/继续；③ 无朗读进度/当前段高亮；④ 一章读完自动停，不自动续读下一章；⑤ 切章即停止。
- 影响: 听书场景功能明显不足（续听做不到、长书无法连续听），与"朗读设置"面板的丰富度不匹配。
- 建议: 支持从当前页开始朗读、暂停/继续按钮、读完自动进入下一章继续（需感知 chapter 切换后重读）、朗读中章节标题高亮/底部进度提示。

### UX-08　阅读页无时间/电量等常规信息栏（P2）
- 文件: reader_page.dart（顶栏仅章节标题）
- 现状: 阅读页内无法看到当前时间，需退出阅读页。
- 影响: 夜间/长时间阅读时看时间成本高。
- 建议: 顶栏或状态栏区域显示时间（可选开关）。

### UX-09　正文不可选择/复制/划线（P2）
- 文件: page_view_widget.dart:203-273；scroll_view_widget.dart:171-244
- 现状: 正文均为普通 `Text`，无 `SelectableText` 或长按选区。
- 影响: 无法复制精彩片段/生词查询；"添加笔记"只能手打，无法选中文字自动带引用。
- 建议: 长按正文弹出选区，提供"复制/笔记/划线"菜单（SelectableText 或自绘选区）。注意与点击翻页手势的冲突处理（长按 vs 单击）。

### UX-10　书签/笔记入口深藏"更多"二级菜单，正文无书签标记（P2）
- 文件: reader_page.dart:586-690（PopupMenu）；bookmark_service.dart
- 现状: "添加书签/添加笔记"都在"更多"下拉菜单第二屏；添加后仅 SnackBar 提示，正文/页边无书签视觉标记。
- 影响: 高频操作成本高（两步点击），且无法回看"哪些页有书签"。
- 建议: 三区菜单或长按菜单直达书签/笔记；翻页模式页眉/页脚显示当前页书签标记；书签列表支持展示摘录片段。

### UX-11　字号/行距/段距滑块拖动无实时预览（P2）
- 文件: lib/features/reader/presentation/widgets/reader_settings_panel.dart:132-155,163-195,199-231
- 现状: onChanged 只更新本地 `_previewXxx` 变量（仅用于滑块自身回显），正文不重排；onChangeEnd 才应用。拖动全程正文无任何变化。
- 影响: 用户感觉滑块"没反应"，只能松手看结果，调字号要反复试错。
- 建议: 拖动节流（150-250ms 合并）后即时重排预览；或应用后保留最后预览值（分页缓存已有，成本低）。

### UX-12　状态栏图标颜色未随阅读主题适配（P2）
- 文件: reader_page.dart:527-529；全项目无 AnnotatedRegion/SystemUiOverlayStyle（已 grep 确认）
- 现状: Scaffold 背景色=阅读主题色，但未设置状态栏前景色；系统浅色模式下夜间/深色阅读主题的状态栏图标仍为深色，对比度低。
- 影响: 夜间主题下状态栏时间/图标看不清。
- 建议: 按 `theme.backgroundColor` 亮度包一层 `AnnotatedRegion<SystemUiOverlayStyle>`（深背景 → light 图标）。

### UX-13　目录面板缺"当前章节定位/搜索/加载失败重试"（P2）
- 文件: lib/features/reader/presentation/widgets/chapter_catalog_sheet.dart:33-61
- 现状: 目录 sheet 打开时**不会自动滚动到当前章节**；无目录内搜索；目录加载失败（catalog 为 null）只显示"暂无目录"，无重试入口。
- 影响: 千章书籍找章节靠手滑；目录失败后无法在面板内重试。
- 建议: 打开时 ListView 定位到当前章节；加目录搜索框（标题过滤）；catalog 为 null 时显示"加载失败，点击重试"。

### UX-14　章节内搜索仅回车触发、跳转无命中高亮（P2）
- 文件: lib/features/reader/presentation/widgets/chapter_search_sheet.dart:25-35,80
- 现状: 输入不实时搜索，需按回车/提交键；跳转后正文无命中高亮，只显示"第 X/Y 处"。
- 影响: 搜索体验单薄，命中定位靠肉眼找。
- 建议: 输入防抖 300ms 自动搜索；翻页模式命中页正文用 TextSpan 高亮关键词。

## 四、详情页 / 书架 / 搜索体验（P2）

### UX-15　详情页"开始阅读"文案不准确：有进度时应为"继续阅读"（P2）
- 文件: lib/features/reader/presentation/pages/book_detail_page.dart:461-467,120-129
- 现状: 按钮恒为"开始阅读"；但 `_openAt(0)` 不会覆盖进度（chapterIndex>0 才写），阅读器内部实际按已存进度续读。
- 影响: 用户预期"从头开始"，实际从上次进度续读，语义矛盾（反向亦然）。
- 建议: 有保存进度时按钮文案改为"继续阅读 42%"；点击后仍续读；需要从头读时提供"从头开始"次级入口。

### UX-16　详情页目录整页全量构建（P2，性能即体验）
- 文件: book_detail_page.dart:610-623（`..._catalog!.chapters.map((chapter) => ListTile(...))`）
- 现状: 将全部章节展开为 ListView children，一次性创建上千个 ListTile。
- 影响: 千章书籍详情页打开明显卡顿、内存峰值高。
- 建议: 改 `ListView.builder`（itemCount+itemBuilder），顺手获得懒加载。

### UX-17　详情页加载串行：详情+目录两个请求排队（P2）
- 文件: book_detail_page.dart:55-83
- 现状: 先 await getBookDetail，再 await getCatalog，两个网络请求串行，白屏时间=两者之和。
- 建议: `Future.wait` 并行；正文区先渲染"简介/开始阅读"，目录异步到达后再填充。

### UX-18　书架无"查看详情"入口，点击只能进阅读器（P2）
- 文件: lib/features/bookshelf/presentation/pages/bookshelf_page.dart:536,543（onBookTap=_openReader）；长按菜单仅 更新详情/清除缓存（158-186）
- 现状: 点击书籍=直接进阅读器续读；长按菜单也没有"详情/简介/目录/换源/导出"。
- 影响: 想看重读简介、看目录、换书源、导出，只能重新搜索，路径缺失。
- 建议: 长按菜单增加"查看详情"（push /book-detail）；或点击封面进详情、点进度条/继续阅读区直接进阅读器。

### UX-19　搜索"加载更多"为手动按钮，无自动分页（P3，可接受但可优化）
- 文件: lib/features/search/presentation/pages/search_page.dart:216-227
- 现状: 需点击"加载更多"按钮翻页。
- 建议: 滚动到底部自动触发 `_loadMore`（有 `_loadingMore` 防重入，成本低）。

## 五、细节 / 增强项（P3）

- UX-20 设置面板无"恢复默认"按钮（reader_settings_panel.dart）——调乱后只能手动滑回。
- UX-21 阅读器不支持"横屏偏好/音量键翻页/翻页方向"等自定义（reader_page.dart/reader_settings_panel.dart）——横屏自动双栏为硬编码。
- UX-22 翻页动画"仿真/覆盖"仅作页面级 3D 变换，非真翻页卷曲，切换动画差异小（page_view_widget.dart:282-295）。
- UX-23 图片章节无"保存图片/旋转"能力（image_reader_widget.dart）——长按保存即可。
- UX-24 SnackBar 均用默认 2s 时长，切书源/自动换源等长文案提示偏短（reader_page.dart:316-324 等）——可设 3-4s。
- UX-25 "搜索本章"菜单项在图片章节无意义，应隐藏（reader_page.dart:649-652）。
- UX-26 书架"更新全部详情"串行逐个请求，无进度（bookshelf_page.dart:229-242）——可改为并发+进度计数。
- UX-27 阅读统计只记录时长，无"本书阅读时长/每日曲线入口"（reading_stats_page.dart）——增强项。

## 六、优先修复建议（Top 8）

| 优先级 | 问题 | 一句话方案 |
| --- | --- | --- |
| 1 | UX-01 无点击翻页 | 正文三区点击：左右翻页、中间呼出菜单 |
| 2 | UX-02 末页无法进下一章 | 末页右滑/按钮触发 nextChapter |
| 3 | UX-03 模式切换丢位置 | scrollOffset ↔ pageIndex 按比例互算 |
| 4 | UX-04 顶栏常驻 | 默认隐藏，点中间呼出 |
| 5 | UX-05 滚动无进度 | 底部加 scrollOffset 进度条 |
| 6 | UX-06 切章闪转圈 | 缓存优先 + 保留旧内容过渡 |
| 7 | UX-07 TTS 从章首/无暂停 | 从当前页起读 + 暂停/续读 + 自动续章 |
| 8 | UX-15/18 详情/书架入口 | "继续阅读"文案 + 书架长按进详情 |

> 说明：UX-09（文字选择）、UX-10（书签直达）、UX-13（目录定位）与既有报告 P2-8/P2-9 的"滚动书签 offset/章节搜索"属不同问题（前者是交互入口/视觉反馈，后者是功能正确性），建议一并排期。

---

## 修复进度（2026-08 体验轮，dart analyze lib 全量通过 + flutter test 全量通过）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| UX-01 | 翻页模式正文三区点击：左=上一页（首屏切上一章）、右=下一页（末屏切下一章）、中=呼出菜单；加载中不响应 | page_view_widget.dart |
| UX-02 | 末页右滑/首页左滑（OverscrollNotification）触发切章；双栏末屏保留"本章完"占位 | page_view_widget.dart |
| UX-03 | 滚动↔翻页模式切换位置互算：scroll→page 按 scrollOffset×页数换算页码；page→scroll 按 pageIndex/页数换算 scrollOffset | reader_provider.dart |
| UX-04 | 顶栏随设置面板显隐（AnimatedSize 沉浸式）；设置面板头部新增返回/章节标题/收起 | reader_page.dart、reader_settings_panel.dart |
| UX-05 | 滚动模式底部新增本章进度条 + 时间 + 百分比 | scroll_view_widget.dart |
| UX-06 | 切章加载保留旧内容，顶部细进度条过渡；仅首次加载显示居中转圈 | page_view_widget.dart、scroll_view_widget.dart |
| UX-07 | TTS 三态（播放/暂停/继续）；从当前页/滚动位置起读；读完自动续读下一章；设置面板新增"停止朗读" | tts_service.dart、reader_page.dart、reader_settings_panel.dart |
| UX-08 | 阅读页底部栏显示当前时间（每分钟刷新） | page_view_widget.dart、scroll_view_widget.dart |
| UX-10 | 长按正文任意位置=添加书签（SnackBar 反馈，轻量直达入口） | reader_page.dart |
| UX-11 | 字号/行距/段距/页边距滑块拖动节流实时重排预览（updateLayout 增加 persist 参数，预览不写盘，抬手落盘） | reader_settings_panel.dart、reader_provider.dart |
| UX-12 | AnnotatedRegion 按阅读主题亮度适配状态栏图标颜色 | reader_page.dart |
| UX-13 | 目录面板打开定位到当前章节、目录加载失败可重试（新增 reloadCatalog） | chapter_catalog_sheet.dart、reader_provider.dart |
| UX-14 | 章节内搜索输入防抖 300ms 自动搜索；正文命中关键词高亮；面板关闭清除高亮 | chapter_search_sheet.dart、page_view_widget.dart、scroll_view_widget.dart、reader_provider.dart |
| UX-15 | 详情页"开始阅读"→ 有进度时"继续阅读 N%" | book_detail_page.dart |
| UX-16 | 详情页目录改独立滚动区域 + ListView.builder 惰性构建 | book_detail_page.dart |
| UX-17 | 详情页详情/目录/进度并行拉取（Future.wait） | book_detail_page.dart |
| UX-18 | 书架长按新增"查看详情"（简介/目录/换源/导出） | bookshelf_page.dart |
| UX-19 | 搜索滚动到底 200px 内自动加载下一页 | search_page.dart |
| UX-20 | 设置面板新增"恢复默认设置"（弹确认，重置全局排版/主题/模式） | reader_settings_panel.dart、reader_provider.dart |
| UX-24 | SnackBar 时长核对：Flutter 默认 4s，无需调整（原报告 2s 描述有误） | - |
| UX-25 | 图片章节隐藏"搜索本章"菜单项 | reader_page.dart |
| UX-26 | 书架"更新全部详情"改分批并发（每批 4 个）+ 完成计数反馈 | bookshelf_page.dart |
| 回归 | 修复 P2-11 遗留回归：图片错误态 TextButton 拦截点击；改为错误态点击=重试、正常态点击=切换设置栏（_handleTap 分发）；测试改用 debugNetworkImageHttpClientProvider mock 成功图片并补错误态重试用例 | image_reader_widget.dart、image_reader_test.dart |
| 回归 | 修复 webdav_backup_scheduler_test 的 _FakeBackupRestore.buildBackupJson 缺 includeSensitive 命名参数（P1-1 遗留编译错误） | webdav_backup_scheduler_test.dart |

暂缓项（结构性/需新增依赖，已记录）：UX-09（正文选词复制——与点击翻页手势冲突，需选区方案）、UX-21（音量键/横屏偏好）、UX-22（真翻页卷曲动画）、UX-23（图片保存/旋转）、UX-27（按书阅读统计）。

| UX-27 | 阅读统计新增按书维度：recordSession 记录 bookId，统计页新增"按书阅读时长 Top 5"（书名映射自书架） | reading_stats_service.dart、reading_stats.dart、reading_stats_page.dart、reader_page.dart |

> 最终验证：`dart analyze lib test` 0 issues；`flutter test` 全量 502+ 用例全部通过（含新增图片错误态重试、成功图片 mock 用例与 webdav 编译修复）。

---

## 第 2 轮追加修复（UX-09 / UX-23，dart analyze 通过 + reader 142 测试全绿）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| UX-09 | 正文选词复制：翻页/滚动正文包裹 SelectionArea（长按选词，默认工具栏复制/全选）；原"长按加书签"让位于选词（书签保留在"更多"菜单） | page_view_widget.dart、scroll_view_widget.dart、reader_page.dart |
| UX-23 | 图片章节"更多"菜单新增"保存当前图片"：Dio 下载 bytes → FilePicker 系统保存对话框（复用既有依赖，无新插件） | reader_page.dart |

最终暂缓（技术受限/低收益，已评估）：UX-21 音量键翻页（Flutter 层无法拦截移动端系统音量键，需原生插件）、UX-22 真翻页卷曲动画（Canvas 自绘大工程，现有仿真/滑动/覆盖三种动画已覆盖）。
