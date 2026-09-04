# EasyRead 多格式书源兼容 — 续接文档（2026-08-05，最新：2026-09-03）

> 重开会话请先读此文件 + 最近 git log。
> **当前主线：docs/LEGADO_PARITY_PLAN.md（对标 Legado）+ .research/00_学习路线图.md。**
> **🎉 路线图全部完成（2026-09-03 十四轮）：P0 13/13 + §二 15/15 + §三 12/12。**

## ⚠️ 最新状态（2026-09-03 十五轮）：全量自查 → 6 项修复（546 测试全绿 + analyze 0）

- **审查发现与修复**（全部有回归测试）：①流式分页 await 后补 seq 防护（reader_provider loadChapter/setChineseMode——旧加载的部分页不得覆盖新章状态）；②订阅容器子地址 `allowContainer:false`（容器不递归，防恶意容器链）；③reader 仓库 `_getStringWithLoginCheck` 补登录失效检测（error:/startBrowser+无 Cookie → ChapterLoadException(sourceError)）+ cookieHeader 透传（消除与 search 仓库的实现漂移；行为变化：需网页登录且未登录的源在阅读流程现在明确报「登录已失效」而非静默继续）；④`SearchRepositoryImpl.logoutSource`（内存会话缓存立即失效 + 加密盒清除），书源菜单「退出登录」改走此 API（原实现 TTL 30 分钟内仍带旧 Cookie）；⑤dio `_decodeBody` 补 UTF-16LE/BE 解码（BOM 定端序，无 BOM 按 RFC 2781 大端）；⑥`requestString` 重试白名单化（仅 connection/send/receiveTimeout/connectionError/badCertificate，cancel 与 badResponse 不重试）；⑦.gitignore 加 `.test_baseline.log` 并删除该日志。
- **回归测试 +7**：reader 登录失效分类、订阅容器不递归、logoutSource 缓存失效、UTF-16 解码×2、badResponse 不重试、取消不重试。
- **进度：P0 13/13 ✅；§二 15/15 ✅；§三 12/12 ✅；546 全绿。待用户 review/commit。**

## ⚠️ 最新状态（2026-09-03 十四轮）：§三 12/12——流式分批排版（539 测试全绿 + analyze 0）

- **§三-12 流式排版**：`PageLayout.paginateStreaming`——节点按批（默认 40）处理，批间 `Future.delayed(Duration.zero)` 让渡事件循环，长章节排版不再一次性阻塞主 isolate 数百毫秒；`onPartial` 渐进回调（已完成页快照）、`isCancelled` 提前停止；与同步 `paginate` 结果逐页一致（共用 `_processNode` 单节点核心 + `_PaginationCursor`）。**引擎约束（实验证实）**：TextPainter 依赖 ParagraphBuilder，后台 isolate 抛 "UI actions are only available on root isolate"——无法下沉 compute/isolate.run，分批让渡是本引擎版本下的等价方案（已写入代码注释）。
- **接线**：reader_provider `loadChapter`/`setChineseMode` 改走 `_paginateStreamingCached`（与 `_paginate` 共用缓存键 + LRU；isCancelled= seq 检查，被新加载取代时丢弃结果不落缓存）；`setViewport` 保持同步（旋转罕见且缓存命中）。
- **测试**：page_layout_test(+4)：流式==同步、onPartial 增长前缀、isCancelled 部分结果、批大小无关性。
- **进度：P0 13/13 ✅；§二 15/15 ✅；§三 12/12 ✅；全绿。路线图收口。**

## ⚠️ 最新状态（2026-09-03 十三轮）：§三 11/12——书源检测全链路深化（535 测试全绿 + analyze 0）

- **§三-11 检测深化**：①`TestBookSource.testFullChain`——搜索 → 目录（chapterList 规则缺失打「目录规则为空」）→ 首章正文，逐级打失效分组标签（搜索失效/目录失效/正文失效/详情链接缺失，Legado CheckSourceService addGroup 语义）；搜索失败短路；readerRepo 可选注入（null 时退化为纯搜索检测）。②`BookSourceTestRecord.groups` 字段（序列化 round trip），批测 `_testOne` 改走全链路，groups 非空判不可用、error=groups.join('、')。③源级 `checkKeyWord` 覆盖批测统一词（testFullChain 内解析，使覆写 testSearch 的测试桩同样生效；Legado BookSource.getCheckKeyword）。④`perSourceTimeout` 从 static const 改实例字段可注入（默认 8s）。测试 source_full_chain_test(+5：全链路可用/目录失效/正文失效/groups 持久化/检测词覆盖)
- **进度：P0 13/13；§二 15/15；§三 11/12（剩余 1：isolate 流式排版）；全绿。**

## ⚠️ 最新状态（2026-09-03 十二轮）：§三 10/12——书源订阅最小方案（530 测试全绿 + analyze 0）

- **§三-9 订阅**：①订阅容器——导入内容为 `{"sourceUrls":[...]}` 时递归拉取子地址合并书源（Legado ImportBookSourceViewModel $.sourceUrls；深度 1、总数封顶 20、单地址失败不中断、全失败给明确文案）；②订阅盒 `SourceSubscriptionStore`（Hive JSON 盒）+ 内存默认实现（usecase 默认内存实现零依赖，应用入口注入 Hive 实现；recordChecked 失败不阻断导入）；③URL 导入成功即记录订阅（url+lastCheckedAt+源数）；④`refreshSubscriptions()` 一键更新（合并语义沿用 _saveMerged：本地较新跳过/保留启用与分组）；⑤入口——导入页传持久盒 + 源列表菜单「刷新订阅」（汇总 N/M 成功、合并总数，刷新列表）。测试 import_book_source_test(+4：容器递归+失败容忍/全失败文案/一键更新/空订阅)
- **进度：P0 13/13；§二 15/15；§三 10/12（剩余 2：isolate 流式排版/书源检测深化）；全绿。**

## ⚠️ 最新状态（2026-09-03 十一轮）：§三 9/12——登录补口 + 章节缓存字节预算收尾（526 测试全绿 + analyze 0）

- **§三-7 登录补口**：①`SourceLoginExpiredException`（登录失效专用错误）——loginCheckJs 结果或规则原文带 `error:` 前缀 → 透传失效原因；loginCheckJs 需 startBrowser 交互登录（本应用无 WebView 通道，桥返回空）且无登录 Cookie → 明确「登录已失效」引导重新登录，不与笼统书源失败混淆（throwOnError 流程透传到检测/聚合上层）；②登出入口——书源菜单「退出登录」清 CookieJarService 加密盒会话；③cookie 二级域名归一化（Legado CookieStore.getSubDomain）——JS 桥 `__cookieLookup`：精确键 → 同主机键 → 同二级域名键（www 存 m 读），`cookie.getCookie`/`java.getCookie` 均走该链。测试 js_rule_executor_test(+3) + search_repository_headers_test(+2)
- **§三-6 收尾（charset 三级检测/BOM 已在 P1-12）**：章节缓存加**字节预算**（条目数 500 + 总字节 64MB 双限并行，超限淘汰最旧；体积按 content 码元数近似，`cacheByteBudget` 可注入）。测试 chapter_cache_budget_test(+2)
- **进度：P0 13/13；§二 15/15；§三 9/12（剩余 3：isolate 流式排版/书源检测深化/订阅）；全绿。**

## ⚠️ 最新状态（2026-09-03 十轮）：§三 7/12——简繁转换移至净化前 + getChapter 失败重试（519 测试全绿 + analyze 0）

- **§三-11 简繁转换移至净化前**（对齐 ContentProcessor.getContent 顺序 chineseConvert → 替换规则）：`ReaderRepository.getChapter` 增 `chineseMode` 参数（domain 接口 import settings 实体）；`_applyUserPurify` 内先 `ChineseConversion.convert` 正文/标题再套净化规则——**繁体站配简体净化规则可命中**；缓存仍存源层原文（转换属阅读时变换，不落缓存）；provider 在 getChapter 前加载模式并传入，`_parseChapterContent` 不再二次转换。测试 chapter_preprocess_test（繁体內容+简体规则命中/默认原文不命中）
- **§三-12 getChapter 失败重试**（对齐 CacheBook 失败重试 3 次）：`_fetchContentPageWithRetry` 包住正文首取 + nextContentUrl 翻页两处抓取——仅重试瞬时网络异常（DioException，书源级 ChapterLoadException 立即抛），默认 3 次/1s 间隔（`contentRetryInterval` 可注入供测试）；耗尽后 rethrow → 归 networkError（不触发自动换源，与 §三-2 闭环）。测试 chapter_preprocess_test（重试成功/耗尽抛错计数）
- **进度：P0 13/13；§二 15/15；§三 7/12（剩余 5：isolate 排版/HTTP charset 检测深化/登录补口/书源检测深化/订阅）；全绿。**

## ⚠️ 最新状态（2026-09-03 九轮）：§三 5/12——自动换源判定重做 + 目录标题净化/bookUrlPattern 生效（515 测试全绿 + analyze 0）

- **§三-2 自动换源判定重做**（对齐 ReadBookViewModel.autoChangeSource）：①`ChapterErrorKind`（sourceError/networkError）——getChapter 兜底 catch 归 networkError，瞬时网络异常**不触发**自动换源；②AutoSwitchSource 重写为**并发池 16**（mapParallelSafe(threadCount).take(1) 语义：next 游标分发、首个通过 completer 胜出、其余跑完忽略）；③候选验证 = 目录非空 + **当前章正文可取**（getChapter(chapterIndex)，越界取最后一章 Legado getOrElse{last}；验证成功还会预热该源章节缓存）；④ReaderState 增 errorKind/errorChapterIndex，reader_page 仅 sourceError 触发并传出错章索引。测试 auto_switch_source_test(+5) + chapter_empty_error_test(+2 kind 分类)
- **§三-10 目录标题净化 + bookUrlPattern 生效**：①getCatalog 两条出口（内存缓存命中/新取）统一经 `_purifyCatalogTitles` 套标题作用域规则（缓存存原始标题，改规则即生效，与正文双层同原则）；②bookUrlPattern 从 no-op 变生效（Legado BookList.kt:50「链接为详情页」判定）——详情页 URL 不匹配 pattern 抛 sourceError（换源候选被拒/正常加载明确报错），空 pattern 放行。测试 catalog_title_purify_test(+2) + rule_wiring_test bookUrlPattern 重写(+1)
- **进度：P0 13/13；§二 15/15；§三 5/12（剩余：isolate 排版/HTTP charset 检测深化/登录补口/书源检测深化/订阅/简繁顺序/getChapter 重试 7 项）；全绿。**

## ⚠️ 最新状态（2026-09-03 八轮）：§三 体验 3/12——净化双层时机 + 图片管线 + 封面防盗链（505 测试全绿 + analyze 0）

- **§三-1 净化双层时机**（对齐 Legado BookContent/ContentProcessor 分层）：章节缓存只存「源规则后原文」（含图片 URL 解析 + 重复标题去除，源层）；用户净化规则（正文/标题作用域）**阅读时套用**（`_applyUserPurify`，getChapter 缓存命中与新取两条路径统一出口）——改用户规则无需清缓存即生效；净化后为空且原文非空仍报「章节内容为空」。测试 purify_layering_test.dart（2）
- **§三-4 图片管线**（对齐 HtmlFormatter.formatKeepImg）：resolveImageUrls 取值优先级 = src 含 `{...}` 模板（拆 `,{json}` 参数：URL 解析绝对、参数原样保留）→ data-* 懒加载兜底 → 普通 src；img 统一归一 `<img src>`（去其余属性）；属性实体由 html 解析器解码（&amp;→&）。测试 image_url_resolve_test.dart（8）
- **§三-3 封面防盗链**（对齐 OkHttpStreamFetcher）：DioClient.getBytes（二进制走完整 _send 管线：SSRF/cookie 回写/限流）→ ReaderRepositoryImpl.fetchImageBytes（书源 requestHeaders（header 规则+Referer 兜底）+ cookie，相对 URL 基于书源地址解析）→ CoverImage widget（Image.memory + 失败 URL 会话级缓存防请求风暴），接入 book_detail_page；9 个测试 fake 补 getBytes stub。测试 cover_image_test.dart（4）
- **进度：P0 13/13；§二 15/15；§三 3/12（下一批：自动换源判定重做 / 目录标题净化 / getChapter 重试）；分析器与测试全绿。**

## ⚠️ 最新状态（2026-09-03 七轮）：P1 URL,{json} 选项 + 全 JS URL——§二 文法/引擎 15/15 全完成（494 测试全绿 + analyze 0）

- **URL,{json} 选项**（新 lib/features/search/data/engines/url_spec.dart，对齐 AnalyzeUrl.kt UrlOption）：切分 `\s*,\s*(?=\{)`；选项 method/headers（对象或 JSON 串，值 toString）/body/charset/type/retry（int，失败重试）/js（result=已解析 URL，结果覆盖 URL）；webView/webJs/serverID 仅识别不实现（本应用无 WebView）；单引号 JSON 容错；选项 JSON 解析失败退化为纯 GET URL
- **全 JS URL**（AnalyzeUrl analyzeJs 语义）：`@js:`/`<js>…</js>` 多段交错，段间文本以 `@result` 引用前段结果、**无标记时覆盖结果**（Legado 语义）；求值顺序=先 JS 段→再切选项→最后选项内 js 字段。JsRuleExecutor.evalUrlJs（新）：绑定 key/page/baseUrl/result + java 桥（模板同款两遍记录-重放，md5/base64 取真实值）；黑名单命中返回空串
- **接入面**：searchUrl/exploreUrl/debugSearch/loginUrl（search_repository_impl，替换原 _parseSearchUrl/_SearchSpec——method/body/charset 之外新增 headers 覆盖源级/retry/js）；tocUrl/nextTocUrl/contentUrl/nextContentUrl（reader_repository_impl._fetchRuleUrl 统一封装，无选项时保持原 headers 引用语义使 Cookie 回写继续传播）
- **DioClient.requestString**（新）：GET/POST(+body) 统一入口，POST 默认表单 Content-Type、显式头优先；retry=N 失败重试；body 不随 GET 发送
- 新增测试 28：url_spec_test(18)、evalUrlJs(3：key/page 绑定、两遍桥真实值、黑名单)、search 全 JS searchUrl+选项 headers(2)、reader tocUrl 选项+JS 段(2)、dio requestString(3)

**进度：P0 13/13；§二 文法/引擎 15/15 全完成；§三 体验 12 项未开始（净化双层时机/自动换源判定/封面防盗链/图片管线/isolate 排版/登录补口/检测深化/订阅/目录标题净化/简繁顺序/getChapter 重试等）。**

## ⚠️ 最新状态（2026-09-03 五/六轮）：P1-15 限流非串行 + P1-14 createSymmetricCrypto 完整 transformation（466 测试全绿 + analyze 0）

- **P1-15** concurrentRate N/M 窗口不串行（rate_limit_interceptor 重写，对齐 ConcurrentRateLimiter.kt）：固定窗口内放行 N+1 个（`window.count > n` 才等待），等待时长按窗口期 `_computeIntervalWaitMs`；不再逐请求串行 sleep。测试：3/300 前 4 次同窗瞬发、第 5 次等 ≥290ms
- **P1-14** `java.createSymmetricCrypto` 完整 JCE transformation 直通（js_crypto.symmetricProcess 重写，对齐 hutool SymmetricCrypto→Cipher.getInstance 语义）：
  - **CTR/SIC**：pointycastle `StreamCipher('AES|DESede/CTR')`（SIC 整计数器大端自增，任意长度）
  - **CFB-N/OFB-N**（N 缺省=块长×8）：手工流式实现（pointycastle 块模式只整块推进，尾部不齐块按 JCE 流语义取密钥流前缀异或；CFB 密文反馈、OFB 密钥流独立），openssl 向量逐字节对齐
  - **GCM**：仅 AES/NoPadding（JCE 同），IvParameterSpec 原样作 nonce（不截断/不散列），tag 固定 128bit、加密封文尾随 tag、解密 tag 校验失败→空串；python cryptography 向量对齐
  - **padding 语义**：省略段=PKCS5（JCE 默认；ECB/CBC 走 PaddedBlockCipher，流式模式手工 PKCS7 填充/剥离）；省略 mode='ECB'；`AES` 单段等价 `AES/ECB/PKCS5Padding`
  - **decodeAesData 对齐 hutool SecureUtil.decode**：纯 hex（任意偶数长度）→hex，否则 base64（旧 `>=32 && %32==0` 限制会误判流式密文）
  - 顺带修复存量 latent bug：ECB/CBC NoPadding 多块数据此前 `BlockCipher.process` 只处理首块（BaseBlockCipher.process 单块语义），改 `_processWholeBlocks` 整块循环 + 长度对齐校验
  - 已知架构限制（非本次引入）：crypto 结果作内层参数的链式调用（`decryptStr(encryptBase64(x))`）在记录-重放两遍模型下回放为空（热身遍内层为占位 ''，final 遍缓存键错位）——crypto 参数依赖 ajax 的场景已由热身重录覆盖
- 新增回归测试 3 个（js_rule_executor_test）：流式三模式 openssl 向量、GCM 加解密/篡改/不支持形态、省略段与默认 padding

**剩余 P1（.research/00_学习路线图.md §二）**：URL,{json} 选项接入 tocUrl/contentUrl、全 JS URL；§三 体验 12 项（净化双层时机/自动换源判定/封面防盗链/图片管线/isolate 排版/登录补口/检测深化/订阅/目录标题净化/简繁顺序/getChapter 重试等）。

## ⚠️ 最新状态（2026-09-03）：P0 语义错误 13 项全部修复（未提交，442 测试全绿）

五路对照研究产出 `.research/00_学习路线图.md` + 01~05 分报告（Legado 源码/反编译 × EasyRead 逐行对照）。按 `.research/实施计划_P0.md` 分 4 批完成全部 13 项 P0 修复，**442 测试全绿 + analyze 0**（基线 417，新增 25 回归测试）：

- **P0-1** legacy 索引 `:` 语义反转 → 离散索引（rule_parser.parseLegacyIndexes，对齐 AnalyzeByJSoup.kt:283）；顺带暴露并修复 `applyReplaceSuffixToValue` replaceFirst 只返回替换串未拼接的存量 bug
- **P0-2** java.get 语义：1参=变量读取（putMap→种子变量→url→DOM 兜底）、2参=get2 网络 GET（js_network 新 kind，键=url|headersJson）
- **P0-3** Dart 侧 variables 注入 `__putMap`（prelude/recordPrelude/全部重置点，变量跨遍可见）
- **P0-4** java.post 返回真实 body（DioClient.postFormFull 新方法）
- **P0-5** ajax/post/get2 网络错误返回 `Exception: <msg>` 错误串（Legado stackTraceStr 语义）
- **P0-6** md5Encode16 = 中段 16 位 substring(8,24)（对齐 MD5Utils.kt）
- **P0-7** timeFormat 1参默认 `yyyy/MM/dd HH:mm`（对齐 AppConst.dateFormat）
- **P0-8** ruleContent.replaceRegex = 完整规则语义：`##` 链（删除/替换/第4段仅首）+ @js: 全规则 + 存量 JSON 数组与 `||` 兼容（applyContentReplaceRegex 转 async）
- **P0-9** nextContentUrl 跨章守卫（nextUrl==下一章 URL 即停，目录取 nextChapterUrl 含相对解析）
- **P0-10** 目录 chapterList `-/+` 前缀（倒序/剥除）+ 章节 URL 空兜底（卷=标题+序号、普通=baseUrl，BookChapterList.kt:230-244）；isVolume 元素级 CSS 查询补 root-inclusive（Jsoup 语义）
- **P0-11** Cookie 全局回写：DioClient._send 逐跳捕获 Set-Cookie → CookieJarService.absorb 按名合并持久化（修复登录态静默衰减）；js_network 出站请求经 execute(cookieHeader:) 注入存储 Cookie（baseHeaders 不覆盖规则自带头、不污染缓存键）
- **P0-12** 书源导入冲突：lastUpdateTime 新者胜（BookSource.lastUpdateTime getter + ImportBookSource._saveMerged——本地较新跳过、导入较新覆盖但保留本地 enabled/group）

已知注意点：purify_rules_test 的 C2 deadline 超时测试在部分子集运行顺序下偶发（全量/单跑均绿，与指令中断预算的时序相关，非本次改动引入）。

**下一步（P1，见 .research/00_学习路线图.md §二/§三）**：URL,{json} 选项接入 tocUrl/contentUrl、全 JS URL、JSON 响应默认 JSONPath、JSONPath &&/|| 语义、索引 [:3]/[3:]/降序、XPath last()/or/!=、java.cache 对象、getElements 动态选择器、jsLib 单次 eval+URL 磁盘缓存、connect/ajaxAll、净化双层时机、自动换源判定重做、封面防盗链等。

## ⚠️ 最新状态（2026-09-03 二轮）：P1 文法/引擎补齐第一批 6 项（452 测试全绿）

- **P1-1** JSONPath 组合语义对齐 Legado AnalyzeByJSonPath：`&&`=全非空拼接、`||`=首个非空、`%%`=下标交错；混合取最后分隔符类型（json_path.dart，原 `&&`=首非空系误读已修正）
- **P1-2** 索引 DSL 端点省略（`[:3]`/`[3:]`/`[:]`）+ end<start 降序（`[3:1]`、`[-1:0]` 反向即降序路径），对齐 AnalyzeByJSoup:431-453（rule_parser.parseIndexSet startOpen/endOpen + selector_engine.expandIndexes）
- **P1-3** JSON 内容 + 裸规则默认 JSONPath（AnalyzeRule.kt:533-536 isJSON 分支）：extractElements/evalString/evalStringList 三处插入，isBareRule+looksLikeJson 辅助
- **P1-4** `<page,N>` page=null 保留占位符（AnalyzeUrl.kt:192 page?.let）——旧「审查修复」按第1页取段系误读，两处旧测试已改
- **P1-5** XPath 补 last()/last()-N、`!=`、starts-with()、or、not()（xpathCondition+xpathElementMatches+非 CSS 可表达条件走元素级过滤）
- **P1-6** java.cache 对象（Legado bindings["cache"]=CacheManager）：裸 `cache` + `java.cache` 双暴露，Hive 盒持久 + TTL 秒 + 过期清理 + 未初始化（Hive 2.2.3 openBox 双发坑）首败永久降级内存（js_cache_store.dart）

**剩余 P1（.research/00_学习路线图.md §二）**：URL,{json} 选项接入 tocUrl/contentUrl（headers/retry/js）、全 JS URL、getElements 动态选择器、getElement Element 风格、jsLib 单次 eval+URL 磁盘缓存、connect/ajaxAll、getString isUrl/unescape 重载、createSymmetricCrypto 完整 transformation、限流 N/M 不串行；§三 体验类 12 项。

## ⚠️ 最新状态（2026-09-03 三轮）：P1 第二批 3 项（458 测试全绿）

- **P1-7** getElements 动态选择器：元素缓存改选择器键控（'docIndex|sel'，js_record_replay.replayOps），final 遍按选择器取缓存（不再依赖调用序号）；java.get 动态选择器（首参变量/含 `+` 拼接）整体路由到记录-重放路径（hasDynamicGet 检测）；序列一致性检查收紧为仅 get
- **P1-8** jsLib：URL 条目下载 + JsCacheStore 磁盘缓存（7 天 TTL，fetcher 桩可测）；lib 仅第一次 eval 注入（QuickJS 全局词法环境 let/const 重复声明抛 SyntaxError——原每次 eval 拼入导致 const 类 lib 整规则降级 null）
- **P1-9** getString/getStringList isUrl/unescape 重载：调用级扫描 + 逐字符参数解析（`_parseGetStringCall`，正则嵌套可选组在 Dart RegExp 下行为不稳已弃用）；Legado 重载语义——2 参单布尔=unescape（AnalyzeRule.kt:251）、3 参 (rule, content, isUrl)=isUrl；htmlUnescape + resolveIfUrl 辅助；JS/Dart 两侧 key 归一一致

**剩余 P1（.research/00_学习路线图.md §二）**：URL,{json} 选项接入 tocUrl/contentUrl、全 JS URL、connect/ajaxAll、getElement Element 风格、createSymmetricCrypto 完整 transformation、限流 N/M 不串行；§三 体验 12 项。

## ⚠️ 最新状态（2026-09-03 四轮）：P1 第三批 3 项（463 测试全绿）

- **P1-10** java.connect/ajaxAll：connect 返回完整 StrResponse（status/header/headers/cookies/body）——DioClient 新增 getResponse（body+headers+status）；fetchNetworkResults 加 'connect' kind（fetcher 桩优先）；键=url|headersJson（缺省 '{}' 归一）；ajaxAll 复用 ajax 管道（__ajaxUrls 收集 + 缓存优先 stub）；executor 外层条件补 hasAjaxAll/hasConnect
- **P1-11** getElement 单参返回 Element 风格对象（html/text/ownText/attr）：record 模式 push 'getElement' op → replayOps 取首元素快照（'docIndex|sel' 键）→ final 返回快照对象；两参保持字符串行为；单参规则经 hasGetElement 路由到记录-重放路径（静态预提取只缓存字符串）
- **P1-12** HTTP charset 三级检测（规则 charset → Content-Type 头 charset → UTF-8 兜底）+ UTF-8/UTF-16 BOM 剥离（dio_client._decodeBody，对齐 Legado OkHttpUtils 三级语义）

**剩余 P1（.research/00_学习路线图.md §二）**：URL,{json} 选项接入 tocUrl/contentUrl、全 JS URL、createSymmetricCrypto 完整 transformation、限流 N/M 不串行；§三 体验 12 项（净化双层时机/自动换源判定/封面防盗链/图片管线/isolate 排版/charset 其余/登录补口/检测深化/订阅/目录标题净化/简繁顺序/getChapter 重试）。

## ⚠️ 最新状态（2026-08-19）：产品收敛为「简单小说阅读器」

## ✅ 审查修复(2026-09-03,未提交,417 测试全绿)

全量代码审查(reviewer 子代理 + 亲审)发现的问题全部修复:
1. **完整执行器 prelude 补 toast/longToast stub**(js_bridge.prelude java 桥):
   此前完整路径脚本调 java.toast 抛 TypeError 整次 eval 失败触发 _recycle
   (记录重放版 prelude 本有 stub,仅主 prelude 漏)。
2. **字段级 jsLib 透传**:_extractField(search 12+ 调用点)/extractField/
   extractFromPage 签名与全部调用点补 jsLib;三处 `JsTemplateEngine.canHandle`
   分支加 `jsLib == null &&` 前置——canHandle 会把 lib 自定义函数误判为
   模板子集导致静默失败,jsLib 非空一律走完整执行器。
3. **`<page,N>` 占位符 page=null 按第 1 页**(rule_template):不再原样残留;
   旧测试"缺省原样保留"断言的是 bug 本身,已翻转。
4. **concurrentRate 兼容 JSON 数字型与空白串**(book_source.dart):
   `"concurrentRate": 1000` 数字、`'  '` 空白、`0/0.0` 归一;
   N/M/单数字行为不变。
5. RateLimitInterceptor 放行后惰性清理过期窗口(10 分钟),删源后 Map 不无界残留。
新增测试:review_fixes_test(9)+ catalog_jslib_passthrough_test(3)。


## ✅ C2 净化规则 scope/超时(2026-09-03,未提交)

对标 legado C2(LEGADO_PARITY_PLAN.md),全部落地,405 测试全绿 + analyze 0:

1. **scope/excludeScope 生效**(legado ReplaceRuleDao 语义):
   - legado SQL `scope LIKE '%name%'`:scope 串包含书名/源 origin → EasyRead 原
     `target.contains(item)` 方向相反。已改为**双向 contains**(scope 项含书名/源
     或书名/源含 scope 项均命中),legado 精确书名导入与 EasyRead 短前缀习惯都工作。
   - 匹配目标:书名 + 源名 + **源 URL**(bookSourceUrl,legado origin 是 URL)。
   - `regex_purifier.dart` `_matchesScope` + `scopedFor({bookName, sourceName, sourceUrl})`;
     `reader_repository_impl` 两处净化调用已补传 sourceUrl。
2. **规则超时自动禁用**(legado ContentProcessor/RegexExtensions 语义):
   - Dart 规则:**Isolate 逐条执行**,超时(默认 3000ms,`timeoutMillisecond`
     字段经 `_validTimeoutMs` 接线:<=0→null→回落默认)kill isolate 抛
     TimeoutException → 回调。卡死正则不再阻塞事件循环。
   - **worker 探活**(advisor 复查修复):Isolate.spawn 带 onExit 端口,
     超时先查 `exited` Completer——worker 已退出(基础设施故障)→ 主
     isolate 同步重试一次,不误判超时;spawn 失败同样降级同步执行。
     仅 worker 存活却超时才触发回调,防止基础设施故障静默禁掉全部规则。
   - JS 规则:**规则级 deadline**(`_applyRule` 开头计算,覆盖匹配收集 +
     全部匹配的替换脚本执行;此前 `_transform` 每匹配各享 3s,100 匹配最坏
     300s)。`_collectMatches`/`_transform` 均按剩余时间限时,零剩余前置检查。
     deadline 先于 quickjs 指令中断(约1-3s)触发 → 超时回调真实可达
     (有测试断言必回调,堵接线静默)。
   - **flaky 挂起修复**(quickjs.dart `forceDispose` + js_purifier 超时分支):
     直接 kill 卡在 FFI eval 的引擎 isolate,退场要等指令中断原生调用返回,
     测试 runner 等待该 isolate 时后续测试"did not complete"。修法:
     ①超时分支先 `engine.dispose()` 100ms 优雅协议回收,失败才硬杀
     (指令中断后 isolate 可正常退场,dispose 响应正常);②forceDispose
     先 kill 后 close 端口(终止事件经仍开放端口送达)。验证:净化组 ×3
     + 双文件 ×2 + 全量,全绿。
   - `PurifyPipeline` + `buildPurifyPipeline` 工厂:超时 → 会话级禁用(withoutRules)
     + `onRuleDisabled(ruleId)` 通知(同规则去重)。
   - `purify_pipeline_provider`:onRuleDisabled → `ManagePurificationRules.disableRule`
     → Hive enabled=false 持久化(下次冷启动/规则刷新自然排除;不 invalidate
     provider 避免阅读中管线重建抖动)。
   - **_buildPurifier 透传 id/timeoutMs**(blocker 修复):三处构造点
     (JS 替换/Dart/catch fallback)均已补 `id: rule.id` +
     `timeoutMs: _validTimeoutMs(...)`;此前 timeoutMillisecond 零接线,
     真实 legado 规则超时回调拿空 id,disableRule 静默失效。
3. 测试:purify_rules_test 新增 12 个 C2 测试(双向 scope/书A续集语义固定/
   空名防护/源URL/超时回调/映射断言/降级不误回调/会话禁用/持久化幂等),
   405 全绿 + analyze 0。

⚠️ 注意:`PurifyRule`/`JsPurifyRule` 新增 `id`/`timeoutMs` 字段;`RegexPurifier`
新增 `onRuleTimeout`/`onJsRuleTimeout` 回调与 `withoutRules`;`JsPurifier` 构造函数
新增 `onRuleTimeout`。

---
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