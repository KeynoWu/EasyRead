# 阅读链路（webBook）对照研究 · 短版
L=Legado (tmp/legado-master/app/src/main/java/io/legado/app/)；E=EasyRead (lib/)。只借鉴机制与语义。
## 1. 目录解析差距（5）
- `-`/`+`反转语义（默认反转）+逐书 reverseToc：L BookChapterList.kt:48-56,119-128 vs E catalog_parser.dart:82-170（无处理）→Legado 源目录顺序错。
- 章节 URL 空兜底：卷=标题+序号、普通=baseUrl：L BookChapterList.kt:230-244 vs E catalog_parser.dart:127（留空）→reader_repository_impl.dart:390-403 全落详情页兜底。
- nextTocUrl：无页数上限仅 visited 防环+多 URL 并发：L BookChapterList.kt:63-115,195-201 vs E reader_repository_impl.dart:204-227（20 页硬上限+单 URL）。
- 去重：L 按 url 唯一（BookChapter.kt:90-94）vs E 按 title|url（reader_repository_impl.dart:229-233），语义不一致。
- 0 章：L 抛 TocEmptyException（BookChapterList.kt:116-118），靠 bookUrlPattern 直达详情+空列表按详情解析兜底（BookList.kt:50-68,87-95）；E 返空目录+详情页读正文（reader_repository_impl.dart:248-259,399-400），bookUrlPattern 仅告警（147-150）。
## 2. 正文提取差距（5）
- 跨章守卫：下一页==下一章 URL 即停（L BookContent.kt:47-52,80-86）vs E 仅 visited（reader_repository_impl.dart:418-444）→下章正文混入当前章。
- URL 选项 ,{json}（method/headers/body/charset/retry/js/webView）：L AnalyzeUrl.kt:208-259,336-408 vs E 仅搜索 URL 支持 method/body/charset（search_repository_impl.dart:768-796），tocUrl/contentUrl 无任何选项。
- JS 渲染源：WebView 渲染页+webJs 轮询≤30s+sourceRegex 嗅探 JS 跳转（L BackstageWebView.kt:108-256, WebBook.kt:335-338）；E 纯 HTTP（reader_repository_impl.dart:105-111）无对等——最大通过率差距。
- formatKeepImg：去非 img 标签+data-* 懒加载兜底+相对 URL 解析+全角缩进+条件 unescapeHtml4（L BookContent.kt:178-182, HtmlFormatter.kt:16-70）；E 仅解析 src（content_extractor.dart:94-112, html_parser.dart:41-51），无实体反转义、懒加载图丢失。
- replaceRegex/content.title 对齐（L BookContent.kt:63-75,136-143 vs E reader_repository_impl.dart:453,455-471），E 多 ReDoS 预检（content_extractor.dart:219-221）。
## 3. 净化时机（3）
- 双层时机：L 取书时执行源规则、阅读时执行用户 ReplaceRule（书名+书源 scope）（L ContentProcessor.kt:91-204）→改规则不清缓存；E 把用户规则烘焙进缓存（reader_repository_impl.dart:482-489,512），缓存 key 不含净化规则（526-558）→改规则后残留旧净化。
- 失败回退对齐：L 规则出错回退原文+正则超时自动禁用（ContentProcessor.kt:128-129,168-171）；E 异常回退原文+超时会话禁用（purify_pipeline.dart:57-59,83-118）。
- 开头重复标题：L 容忍前缀噪声+替换规则显示标题兜底（ContentProcessor.kt:103-127）；E 仅精确开头匹配（content_extractor.dart:75-90）。
## 4. 换源判定（3）
- 触发信号：L 仅在书源被删除时自动（ReadBookViewModel.kt:142）+用户主动（ChangeBookSourceViewModel.kt:505-530）；E 任意单章失败即自动、每会话一次（reader_page.dart:325-329,166-176）→瞬时网络错误误换源。
- 候选校验：L 全源精准搜索（名+作者）→详情→目录→取当前章正文验证（ReadBookViewModel.kt:295-340）；E 仅校验目录非空+搜索时静态替代源（auto_switch_source.dart:34-76）→可能切到正文规则坏源。
- 并发：L mapParallelSafe(threadCount=16)+take(1)（ReadBookViewModel.kt:303-322, AppConfig.kt:233）；E 串行（auto_switch_source.dart:45-74）。
## 5. 书籍信息/封面（2）
- 字段隔离：L 逐字段 try/catch+canReName（BookInfo.kt:66-149）、tocUrl 空回退详情页并缓存 tocHtml 复用（141-149, WebBook.kt:239-246,314-324）；E 字段 JS 已隔离但 CSS 规则异常会炸整个目录（catalog_parser.dart:307-349, reader_repository_impl.dart:176-200,255-259），且不复用 tocHtml（176-193）。
- 封面：L Glide+书源 headers(Referer)+cookie+二次解密+失败缓存（OkHttpStreamFetcher.kt:59-71,106-139）；E Image.network 无 headers（book_detail_page.dart:324-329, search_result_item.dart:120）→防盗链封面 403。
## 6. 性能机制（3）
- 排版：L 后台流式排版逐页 channel 发射+chapterPosition 二分定位（TextChapter.kt:38,226-255,268-279, ReadBook.kt:665-690）；E 主 isolate 全量 TextPainter（reader_provider.dart:618-636, page_layout.dart:48-111）→长章卡顿。
- 缓存：L 一章一文件落盘+内存只载 ±1 章（BookHelp.kt:174-192, ReadBook.kt:624-660）；E 内存 Hive 500 章 LRU（reader_repository_impl.dart:680-692,308-329）。
- 重试/并发：L 失败章 3 次重试+1s 间隔、TOC/正文并发 16（CacheBook.kt:205-217,302-307）；E getChapter 无重试、预加载串行（reader_repository_impl.dart:654-677, book_cache_service.dart:134-159）。
## 7. 总体建议（8）
- P0 解析质量：URL 选项 ,{json}（headers/retry/js/charset/method）接入 tocUrl/contentUrl（L AnalyzeUrl.kt:208-259 vs E search_repository_impl.dart:768-796）。
- P0 解析质量：nextContentUrl 下一章 URL 守卫+移除 20 页硬上限+多 next URL 并发（L BookContent.kt:47-135 vs E reader_repository_impl.dart:204-227,418-444）。
- P0 解析质量：目录 `-`/`+` 反转语义+章节 URL 空兜底（L BookChapterList.kt:48-56,119-128,230-244 vs E catalog_parser.dart:82-170）。
- P0 解析质量：opt-in 无头 WebView 抓取通道（webView:true+webJs 轮询+sourceRegex 嗅探）（L BackstageWebView.kt:108-256, WebBook.kt:335-338）。
- P1 解析质量：图片管线 data-src 懒加载兜底+unescapeHtml4+图片请求带书源 headers(Referer)/cookie/失败缓存（L HtmlFormatter.kt:16-70, OkHttpStreamFetcher.kt:59-139 vs E content_extractor.dart:94-112, scroll_view_widget.dart:296-297）。
- P1 解析质量：原文缓存与用户净化规则分离（缓存源规则后原文、阅读时套用户规则）（L ContentProcessor.kt:91-204 vs E reader_repository_impl.dart:482-512）。
- P1 体验：自动换源=全源精准搜索→目录→当前章正文校验，瞬时错误不触发、候选并发（L ReadBookViewModel.kt:295-340 vs E auto_switch_source.dart:34-76, reader_page.dart:325-329）。
- P1 体验：后台 isolate 流式排版+章内字符偏移进度+标题相似重锚（L TextChapter.kt:38,226-255, BookHelp.kt:485-532 vs E reader_provider.dart:618-636, reading_progress.dart:1-30）。
