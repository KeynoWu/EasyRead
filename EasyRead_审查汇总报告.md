# EasyRead 多维度审查汇总复检报告

> 汇总复检员：reviewer（严重度已按统一标准重排：P0=崩溃/数据丢失/安全可远程利用；P1=核心功能错误或明显安全风险；P2=边界缺陷/健壮性；P3=代码质量/维护性）
> 数据来源：architect / security / engine / reader / storage 五维度共 53 条原始发现，经去重合并后 47 条。已对全部 P0/P1 及代表性 P2/P3 用 read/grep 逐条核对文件与行号，基本准确；个别修正见各条标注。

## 一、总体结论

EasyRead 分层骨架完整、安全基线扎实（SSRF 字面量拦截、密钥与 Cookie 加密盒、JS 沙箱隔离、备份版本校验均有防护），但五维度复检确认 47 个问题：**3 个 P0**（恶意书源可触发 SSRF / Cookie 外泄，加密密钥降级可致敏感数据永久丢失）、**8 个 P1**、**16 个 P2**、**20 个 P3**。最紧迫的是三处 P0，以及阅读器滚动进度、换源变量、备份非原子写入等核心功能缺陷；架构层依赖边界多处击穿、CI 无测试兜底，属长期风险。队友发现的文件/行号经抽查基本准确。

## 二、问题清单

### P0（3）— 崩溃 / 数据丢失 / 安全可远程利用

**P0-1　SSRF 仅校验字面量主机名，DNS 重绑定可绕过读内网**
- 文件: lib/core/network/dio_client.dart:270-291
- 问题: _isHttpUrl 只对 URL 字符串里的 IP/回环/内网/保留段做字面拦截，对域名不做解析。恶意书源可用 127.0.0.1.nip.io / localtest.me / sslip.io 等指向 169.254.169.254、192.168.x.x；java.ajax 把响应回传 JS 规则后可外带。
- 影响: 内网探测/读取（路由器、NAS、云元数据）、凭据外带，可被恶意书源远程触发。
- 建议: 对 hostname 做 DNS 解析并逐一校验解析出的 IP（含逐跳重定向），离线域名解析失败即拒绝；或经统一出站代理校验；考虑书源 URL 白名单。
- 来源: security（reviewer 由 P1 升级为 P0；行号已核对，出站路径无其它限制为“可远程利用”判定依据，⚠️ 建议人工确认实际出站链路是否还有隐藏约束）

**P0-2　JS 规则可读取并外泄用户登录 Cookie 至任意公网地址**
- 文件: lib/features/search/data/engines/js_rule_executor.dart:1861-1942（_cookieBridge）、1610-1649（注入）、518-578（_fetchNetworkResults）
- 问题: 完整 cookie 映射注入不可信 JS，java.getCookie/cookie.getCookie 可读；java.ajax/java.post 接受任意 http(s) URL（仅 IP 级 SSRF 拦截、无出站白名单）并把响应回传。恶意/被投毒书源可静默外泄该源登录态 Cookie；java.post 还允许注入任意请求头（含 Cookie/Authorization）。
- 影响: 付费/会员书源账号会话被盗，远程内容触发。
- 建议: ajax 目标限与书源同域或跨域弹窗确认；不向会发起跨域请求的规则暴露原始 cookie 值；post 头部注入白名单化。
- 来源: security（reviewer 由 P1 升级为 P0；cookie 桥注入与 getCookie 已逐行核对）

**P0-3　Hive 加密密钥降级路径会覆盖已存密钥，加密盒永久不可读**
- 文件: lib/core/database/hive_init.dart:30-53（_getOrCreateCipherKey）
- 问题: _secureStorage.read 抛**非 StateError** 异常（如 Keystore/Keychain 瞬时不可用）时被 catch (_) 吞掉，随后 generateSecureKey() 并 write 回 _cipherKeyName。注释称“不会覆盖已存密钥”，但仅在 write 也失败时才成立；若 read 瞬时失败而 write 成功，旧密钥被覆盖，book_sources/settings/source_subscriptions/cookie_jar 全部加密盒永久无法解密。
- 影响: 静默、不可逆的全量敏感数据丢失（与“恢复失败仍可重试”不同，此处旧密钥已物理消失）。
- 建议: read 任何异常都不得持久化新密钥——要么抛错终止启动，要么仅用内存态密钥并告警，绝不 write 覆盖可能存在的旧密钥。
- 来源: storage（reviewer 由 P1 升级为 P0；代码已逐行核对。⚠️ 触发条件“read 抛非 StateError 且 write 成功”为推测的异常时序，需人工确认 secure storage 平台实现是否可能命中）

### P1（8）— 核心功能错误或明显安全风险

**P1-1　WebDAV 自动备份明文上传含 Cookie/内嵌凭据的完整 JSON（与手动明文导出同根因）**
- 文件: lib/features/settings/data/services/webdav_backup_scheduler.dart:183-203（_doBackup）、lib/features/settings/domain/usecases/webdav_sync.dart:96-110（upload）、lib/features/settings/domain/usecases/backup_restore.dart:33-70（buildBackupJson）、258-288（exportBackup 默认明文）
- 问题: buildBackupJson 无差别打包 cookie_jar 全部 Cookie + book_sources.rules（内嵌 header/cookie 凭据），自动备份直接 PUT 明文；手动导出默认也走明文 .json。
- 影响: WebDAV 服务器（可能第三方）落盘明文凭据；被窃/被托管方读取即全部登录态泄漏。
- 建议: 自动备份走 AES-GCM 加密（或至少敏感字段剥离后上传）；手动导出默认加密或剥离凭据。
- 来源: security（合并其“自动备份明文”P1 与“手动导出明文”P2，同一根因=buildBackupJson 无敏感剥离+明文）

**P1-2　WebDAV 重定向时 Authorization 清除逻辑实际不触发**
- 文件: lib/features/settings/domain/usecases/webdav_sync.dart:63-87（_dio）
- 问题: _dio 未设 followRedirects:false；注释假设 onRequest 在每次重定向跳转重新触发，但 Dio 拦截器每次请求只执行一次，重定向由底层 adapter 内部跟随，跨域 3xx 时 Basic Authorization 是否剥离不受该拦截器控制。
- 影响: Basic 凭据可能被带到新域，远程触发。
- 建议: 设 followRedirects:false 并复用 DioClient 的逐跳解析/校验/敏感头清理逻辑。
- 来源: security（行号已核对，与主网络层 DioClient 的逐跳处理不一致已确认）

**P1-3　净化 Dart 正则主 isolate 同步执行无超时，ReDoS 启发式明显漏报**
- 文件: lib/core/purification/regex_purifier.dart:96-109（purify）、lib/core/purification/purify_pattern_guard.dart:40-59/62-83
- 问题: RegexPurifier.purify 主 isolate 同步 replaceAllMapped，无超时/运行时兜底；PurifyPatternGuard 仅构建期一次启发式过滤，漏掉 (a|aa)+b（组体“a|aa”不含量词）与 (.*a){20}（{20} 定长 _unboundedQuantifierLength 返回 0）等经典灾难性模式；importFromJson/importFromUrl 导入的外部规则同样只过该启发式。
- 影响: 一条漏网规则即可在章节打开时冻结 UI（不可中断），经恶意书源远程触发。
- 建议: Dart 净化规则加每次匹配上限或移入独立 isolate；强化启发式；或落地已解析未使用的 timeoutMillisecond 字段。
- 来源: engine（行号已核对；启发式两处漏报逻辑已确认）

**P1-4　java.post/java.head 网络操作无数量上限，可放大为请求风暴**
- 文件: lib/features/search/data/engines/js_rule_executor.dart:518-578（_fetchNetworkResults，对比 _fetchAll 的 _maxFetchUrls=50 于 441-450）
- 问题: _fetchAll 对 ajax URL 有 50 条裁剪，但 post/head 的 ops 列表无任何数量上限、无整体超时；3s eval 内 JS 可 push 海量 post/head，随后 4 并发 worker 串行消费，总时长与请求量近似无界。
- 影响: 恶意书源 JS 造成长时间后台请求与网络/内存占用（DoS）。
- 建议: post/head 同样施加 _maxFetchUrls 上限或给 fetch 阶段加 wall-clock 预算，超限丢弃。
- 来源: engine（行号已核对）

**P1-5　滚动模式切章后进度串位/不恢复**
- 文件: lib/features/reader/presentation/widgets/scroll_view_widget.dart:17-20,77-91
- 问题: ReaderScrollView 以 const 返回（无 key），切章时 State 被复用；_restoredOffset/_lastReportedOffset/_controller.pixels 不重置；滚动进度是单条 per-book 记录（只存一个 scrollOffset）。
- 影响: 滚动模式切章后停留在上一章像素位置，新章滚动位置永不恢复。
- 建议: didUpdateWidget 或监听 currentChapter.id 变化时重置 _restoredOffset=false、jumpTo(0)；进度改 per-chapter 存储。
- 来源: reader（行号已核对）

**P1-6　滚动位置保存节流丢最终进度**
- 文件: lib/features/reader/presentation/widgets/scroll_view_widget.dart:44-61
- 问题: 上报同时受 0.5% 阈值与 1s 时间节流双重限制，停止滚动的最后一次事件通常落在 1s 窗口内被丢弃；退出时读到陈旧 scrollOffset。
- 影响: 滚动模式最终停留位置丢失（约最后 1 秒滚动），续读错位。
- 建议: 移除 1s 节流仅保留阈值，或 dispose/切章时强制 flush 最终 offset。
- 来源: reader（行号已核对，节流逻辑逐行确认）

**P1-7　换源丢失 @put 变量**
- 文件: lib/features/reader/presentation/pages/reader_page.dart:293-336（_openSourceSwitcher，pushReplacement 在 329-334）；lib/features/reader/presentation/pages/book_detail_page.dart:172-186（_openSourcePicker）
- 问题: _openSourceSwitcher 的 pushReplacement URL 未带 variables；_openSourcePicker 构造新 SearchResult 时漏传 variables（result.variables 在 208 行确有使用，证明字段存在）。
- 影响: 换源后新书源 @get:{key} 变量为空，目录/正文 URL 解析失败或内容错误。
- 建议: 两处都把 variables 一并透传。
- 来源: reader（行号已核对，由原文 322-334 修正为 293-336）

**P1-8　备份恢复非原子：先清空再写入，中途失败丢数据且无回滚**
- 文件: lib/features/settings/domain/usecases/backup_restore.dart:187-242（_clearBox 见 332-337）
- 问题: restoreFromJson 第二阶段对每个盒 _clearBox 后逐条 save/put；Hive 无事务。若 save(book) 在第 N 条抛错，盒已被清空只剩 N-1 条；safe() 仅计数 failures 并返回“恢复完成…N 项写入失败”，无回滚或醒目告警。
- 影响: 恢复操作本身成为数据丢失来源（但备份文件仍在、可重试，故不列 P0）。
- 建议: 先快照当前盒到内存，失败回滚；或写临时盒成功后整体替换；部分失败升级为强告警。
- 来源: storage（行号已核对）

### P2（16）— 边界缺陷 / 健壮性

**P2-1　go_router state.extra 未做类型校验的强制转型**
- 文件: lib/core/router/app_router.dart:65,82,90,96,116,159
- 问题: 多处 state.extra as BookSource?/as DiscoverCategory/as SearchResult；深链直达（无 extra）或类型不符时抛 TypeError。
- 影响: 深链/冷启动恢复/非法 URL 触发路由构建崩溃白屏。
- 建议: 逐处 if (state.extra is T) 或 as T?+null 兜底，为深链补无参分支。
- 来源: architect（行号逐处核对一致）

**P2-2　复杂数据经 URL query 传递（reader 路由）**
- 文件: lib/core/router/app_router.dart:184-199、reader_page.dart:329-334
- 问题: /reader/:bookId 把 sourceId/detailUrl/alternatives(JSON)/variables(JSON) 全塞 query；JSON 含 &、%、+ 与长文本，编解码脆弱、URL 超长、易泄漏。
- 影响: 参数错位/丢失致换源与书源变量失效；与 extra 机制分裂。
- 建议: 改用 context.push(extra: ReaderArgs(...)) 传对象，query 仅留最小可分享标识。
- 来源: architect（与 P1-7 同位置但根因不同：此处为传参机制，P1-7 为漏传 variables 字段）

**P2-3　readerProvider 常驻 Notifier：大状态常驻 + 可变字段分散 + 无 onDispose 清理**
- 文件: lib/features/reader/presentation/providers/reader_provider.dart:147-173,916,1008-1010
- 问题: readerProvider 非 autoDispose，整章正文/pages/pageCache 离开阅读页后仍驻留；ReaderNotifier 大量可变字段（_loadSeq、_syncChain、_saveDebounce Timer、_pageCache）游离于不可变 ReaderState 外；未用 ref.onDispose 取消定时器。
- 影响: 内存持续占用（多章后内存压力），状态来源分散难推理。
- 建议: 明确生命周期（autoDispose+保留必要跨页态），中间态收拢进 state，ref.onDispose 取消 Timer。
- 来源: architect（reviewer 由 P2 维持；与 t4 的 reader 状态类问题不同根因）

**P2-4　##…### 替换（replaceFirst）无匹配时返回替换串而非原值**
- 文件: lib/features/search/data/engines/rule_engine.dart:648-670
- 问题: _applyReplaceSuffixToValue 的 replaceFirst 分支 if (match == null) return suffix.replacement;，模式未命中时直接返回 replacement 丢弃原值；Java/Legado 语义应返回原字符串。
- 影响: 字段值静默污染（如 URL 结构变化后详情 URL 变成“X”），数据正确性。
- 建议: 改为 if (match == null) return value;（现有测试仅覆盖命中分支）。
- 来源: engine（reviewer 由 P1 降为 P2：仅 URL 结构变化等边界触发，属边界缺陷；行号已核对）

**P2-5　净化 scope/excludeScope 用子串匹配误命中范围**
- 文件: lib/core/purification/regex_purifier.dart:76-93
- 问题: _matchesScope 用 target.contains(item)，无词边界/全名匹配；scope“书A”命中“书AB”，excludeScope“A”排除所有含 A 的书/源。
- 影响: 净化规则被应用到错误的书或错误跳过（正确性 bug）。
- 建议: 切分后与 bookName/sourceName 精确（或归一化后精确）相等比较。
- 来源: engine（行号已核对）

**P2-6　JsTemplateEngine.canHandle 黑名单，白名单外能力被静默丢弃**
- 文件: lib/features/search/data/engines/js_template.dart:18-33、search_repository_impl.dart:647-651
- 问题: canHandle 仅用 unsupportedMarkers 黑名单，但模板引擎只实现 java.get/getElement/setContent 与字符串赋值；字段规则含 java.md5Encode/base64Encode/HMacHex/getCookie 等（不含黑名单关键词）被判可处理，随后被静默忽略返回 null。
- 影响: 使用加密/编码辅助函数的字段规则静默失败或产出错误值。
- 建议: canHandle 改白名单，其余一律交 JsRuleExecutor。
- 来源: engine（行号已核对；⚠️ “具体哪些规则被静默丢弃”需人工构造用例确认）

**P2-7　JSONPath 递归下降与 _collectRecursive 无深度上限，深层 JSON 可栈溢出**
- 文件: lib/features/search/data/engines/json_path.dart:118-131（_collectRecursive）、328-526（_FilterParser 递归）
- 问题: 递归收集与过滤器解析均无深度限制，Dart jsonDecode 也无显式深度上限；恶意书源返回数万层嵌套 JSON 可 StackOverflow。
- 影响: 解析崩溃（DoS）。
- 建议: 加深度上限（如 128/256），超限降级返回空。
- 来源: engine（行号已核对；⚠️ 未构造深嵌套 JSON 实测，属推测性崩溃，建议人工复现）

**P2-8　滚动模式书签每章只能一个且不记位置**
- 文件: lib/features/reader/presentation/pages/reader_page.dart:186-211、bookmark_service.dart:129-145
- 问题: _toggleBookmark 用 state.currentPage（滚动模式恒 0）作 pageIndex，exists 按 (chapter,page) 判重，第二个书签被拒。
- 影响: 滚动模式同章只能加一个书签且不记滚动位置。
- 建议: 书签实体加 scrollOffset 维度，滚动模式用 offset 判重/定位。
- 来源: reader（未逐行复核，采纳队友结论）

**P2-9　章节内搜索在滚动模式失效**
- 文件: lib/features/reader/presentation/widgets/chapter_search_sheet.dart:25-34、reader_provider.dart:815-828
- 问题: searchInChapter 仅遍历 state.pages（滚动模式恒空），jumpToPage 在 count=0 时 no-op。
- 影响: 滚动模式“搜索本章”永远无结果。
- 建议: searchInChapter 增加对 state.nodes 的兜底（滚动模式直接匹配并定位）。
- 来源: reader（未逐行复核，采纳队友结论）

**P2-10　缓存进度回调致详情页整页高频重建**
- 文件: lib/features/reader/presentation/pages/book_detail_page.dart:210-213,279-281
- 问题: cacheBook onProgress 每缓存一章就 setState，重建整页（含整个目录 ListView）。
- 影响: 大目录缓存时严重卡顿/掉帧。
- 建议: 用局部 ValueNotifier 只刷新按钮文本，或目录列表独立 widget 隔离重建。
- 来源: reader（行号已核对：setState 在 212、281 两处确认）

**P2-11　图片加载无磁盘缓存/无重试**
- 文件: lib/features/reader/presentation/widgets/page_view_widget.dart:333-357、scroll_view_widget.dart:203-227、image_reader_widget.dart:235-258
- 问题: Image.network 仅配 errorBuilder 显示破碎图标，无重试、无磁盘缓存；内联图用 BoxFit.cover 裁切。
- 影响: 瞬时网络失败留下永久破碎图标，重启后重拉；正文内图被裁切。
- 建议: 引入 cached_network_image/点击重试，内联图改 BoxFit.fitWidth。
- 来源: reader（未逐行复核，采纳队友结论）

**P2-12　整本缓存盒 book_cache 无 LRU/容量上限，磁盘无界增长**
- 文件: lib/features/reader/data/services/book_cache_service.dart:80-132
- 问题: cacheBook 逐章 put 全部章节且从不淘汰；book_cache 无任何 trim（对比 chapters 盒有 maxEntries=500 的 _trimCache）。
- 影响: 缓存多本书后盒无限膨胀占满存储。
- 建议: 按书数/总字节设上限并按 meta.updatedAt 淘汰最旧书。
- 来源: storage（行号已核对，cacheBook 逐章 put 已确认）

**P2-13　book_cache 缓存并发竞态：check-then-act 无锁**
- 文件: lib/features/reader/data/services/book_cache_service.dart:99-123
- 问题: cacheBook 对共享盒 containsKey(102)→getChapter→put(113) 无互斥；换源防护 deleteAll(89) 与 meta put(92) 交错，按 chapter.index 为 key 的 put 丢失换源保护语义。
- 影响: 重复网络请求、缓存混入旧书源章节、meta 与章节不一致。
- 建议: 加 per-book 互斥（Future gate/正在缓存标志），换源清理与写入原子化。
- 来源: storage（行号已核对）

**P2-14　BookModel/ChapterModel/ReadingProgressModel 适配器为位置式编码、无版本号/字段计数**
- 文件: lib/features/bookshelf/data/models/book_model.dart:67-97、chapter_model.dart:68-91、reading_progress_model.dart:62-81
- 问题: 三个 TypeAdapter 按固定位置顺序读写，无字段数/版本标记（对比 BookSourceModelAdapter 用字段数、SourceSubscriptionModelAdapter 用魔数+字段键已具备演进机制）；ChapterModel 的 @HiveField 注解被手动适配器忽略。
- 影响: 未来新增/删除/重排字段时旧盒数据错位解析，静默错值或 EOF 崩溃，无迁移路径（当前 schema 稳定暂不丢数据，故列 P2）。
- 建议: 统一改字段数+字段键+类型化 read，或首字节版本号+逐版本迁移，补向后兼容测试。
- 来源: storage（reviewer 由 P1 降为 P2；行号已核对，位置式读写已确认）

**P2-15　_isPlainBoxOnDisk 依赖 Hive 私有实现与帧格式，版本升级脆弱**
- 文件: lib/core/database/hive_init.dart:103-120、pubspec.yaml:37（hive 2.2.3）
- 问题: 明文探测通过 Hive 强转 HiveImpl 取 homePath，并按 Hive 精确帧/CRC32 二进制布局手算校验；pubspec 用 2.2.3 允许任意 2.x，一旦 Hive 内部字段/帧格式变化，探测静默返回 false，旧明文盒被当加密盒用 cipher 打开失败。
- 影响: 依赖升级可能静默破坏明文迁移（正是该代码要避免的红屏/丢数据路径）。
- 建议: 固定精确版本，或改回先明文尝试失败再加密打开并妥善处理 completer 双重错误，加格式变更回归测试。
- 来源: storage（行号已核对，CRC 帧校验实现已确认）

**P2-16　CI 只有 release 构建，无 analyze/test 步骤**
- 文件: .github/workflows/release.yml:11-53
- 问题: 仅 tag 触发+签名+flutter build apk+发 release，全程无 analyze、无 test、无 PR/push 测试 job；62 个测试文件 CI 永不运行。
- 影响: 上述 P0/P1 及任何回归都无法在 CI 捕获。
- 建议: 新增 test job（pub get→analyze→test），PR/push 触发，release 前强制跑测试。
- 来源: storage（行号已核对）

### P3（20）— 代码质量 / 维护性

**P3-1　架构分层依赖边界击穿（domain→Flutter/data、provider 暴露具体实现、跨 feature 耦合，合并 4 处同根因）**
- 文件: lib/features/settings/domain/usecases/backup_restore.dart:5,410-467；lib/features/bookshelf/domain/usecases/import_local_book.dart:2,5；lib/features/book_source/domain/usecases/import_book_source.dart:6-7；bookshelf_provider.dart:6、book_source_provider.dart:7、search_provider.dart:7、reader_provider.dart:21；search_provider.dart:4、reader_provider.dart:14-18、bookshelf_page.dart:9-12
- 问题: ①domain/usecases 内 import flutter/material.dart 并用 showDialog/TextField 渲染 UI，或用 rootBundle/foundation；②domain usecase 反向 import 其它 feature 的 data model（book_model/chapter_model 等）；③四个 provider 声明为 Provider<XXXRepositoryImpl> 具体类而非 domain 接口；④feature 间经 presentation provider 跨模块耦合。
- 影响: 依赖方向反转、无法脱离 Flutter 纯 Dart 单测、模块边界击穿、改动级联扩散。
- 建议: 弹窗/asset 读取上移 presentation；usecase 只依赖 entity+repository 接口；provider 声明接口类型；跨 feature 依赖收敛到 domain 接口。
- 来源: architect（reviewer 将其 4 条 P1 合并为 1 条并按“代码质量/维护性”统一降为 P3；行号已抽查 backup_restore.dart:5 与 bookshelf_provider.dart:6 确认）

**P3-2　AppRouter.router 为 static final 单例，builder 内 ProviderScope.containerOf 直读**
- 文件: lib/core/router/app_router.dart:31,78-79,107-108
- 问题: GoRouter 全局 static final，脱离 Riverpod 生命周期；builder 里 containerOf(context).read 绕过 ref，与具体 feature provider+全局容器硬耦合。
- 影响: 无法按 ProviderScope 隔离（测试/多容器失效），无祖先时抛异常。
- 建议: 路由改 Riverpod provider（或 refreshListenable），builder 内用 Consumer/ref 读取。
- 来源: architect（reviewer 由 P2 降为 P3：属测试性/可维护性）

**P3-3　app.dart 在 initState 的 microtask 中 ref.read 引导调度器**
- 文件: lib/app.dart:23-37
- 问题: Future.microtask 内 ref.read 启动 AutoRefreshScheduler/WebDavBackupScheduler，dispose 用静态 stop()；microtask 执行前被 dispose 时 ref.read 抛 StateError；调度器为静态单例非 Riverpod 管理。
- 影响: 竞态崩溃风险+服务生命周期与 DI 脱节。
- 建议: 改 provider 持有并借 ref.onDispose 启停，或 ref.read 前判 mounted。
- 来源: architect

**P3-4　purify_pipeline 内联 new 用例 + subscription 仓库缺 domain 抽象**
- 文件: purify_pipeline_provider.dart:8-13；subscription_source/data/repositories/subscription_repository.dart:35-41
- 问题: purify_pipeline 直接 new ManagePurificationRules()（经 rootBundle 耦合 Flutter），无法注入替身；SubscriptionRepository 是 data 层具体类且构造器内 dio??DioClient()、service??SubscriptionSourceService() 自带默认实例化。
- 影响: 与其它 4 个 feature 的 domain 接口约定不一致。
- 建议: 统一仓库抽象到 domain/repositories；用例经 provider 注入，去掉构造器默认 new。
- 来源: architect

**P3-5　日志打印含敏感查询串的完整 URL/异常对象**
- 文件: lib/features/reader/data/repositories/reader_repository_impl.dart:408,152-153；lib/features/book_source/domain/usecases/import_book_source.dart:82,103,106；webdav_backup_scheduler.dart:201
- 问题: debugPrint 输出完整 URL（可能含 token/session 查询参数）与异常对象。
- 影响: logcat/控制台可被读取，凭据泄漏（本地）。
- 建议: 打印前对 query/fragment 脱敏，异常仅打印类型/友好文案。
- 来源: security

**P3-6　JS 沙箱 _ffiNotify/eval 黑名单可绕过（纵深防御，当前影响低）**
- 文件: lib/features/search/data/engines/js_rule_executor.dart:599-606；third_party/quickjs/lib/src/native_js_engine.dart:220
- 问题: 黑名单用字符串 contains，可被 globalThis['_ffi'+'Notify']、(0,eval) 绕过；目前无 registerBridge、timersEnabled=false，_ffiNotify 为空操作，且沙箱有内存/栈/超时/杀 isolate 上限，实际逃逸面小。
- 影响: 纵深防御缺口。
- 建议: 彻底移除 _ffiNotify 绑定，不依赖字符串黑名单；如启用定时器需防 dispose 后 UAF。
- 来源: security

**P3-7　WebDAV 用户名/URL 明文存储 + 允许本机明文 HTTP**
- 文件: lib/features/settings/domain/usecases/webdav_sync.dart:9-11,54-60,140-149
- 问题: 密码入 secure storage（正确），但用户名与服务器 URL 明文落盘（webdav_config 盒）；另允许 http://localhost/127.0.0.1/::1 明文承载 Basic 认证。
- 影响: 用户名/端点暴露、本机明文传输。
- 建议: webdav_config 盒改加密存储；移除或默认关闭 http 例外。
- 来源: security

**P3-8　替换串展开不支持 $&（整体匹配），$$ 处理两处不一致**
- 文件: lib/core/purification/js_purifier.dart:134-147（_expandCaptures）；lib/features/search/data/engines/rule_engine.dart:672-682（_expandReplacement）
- 问题: 两处展开均不支持 $&；js_purifier 对 $$ 原样保留，而 rule_engine 的 _expandReplacement 已正确处理 $$（673-677 行）。
- 影响: 依赖 $& 的净化/替换规则与 Legado 不一致。
- 建议: 两处补齐 $&，js_purifier 补齐 $$。（修正 engine 原文“$$ 两处都未处理”的说法——rule_engine 已处理 $$）
- 来源: engine（reviewer 修正定位）

**P3-9　_lastBookDetail 跨书残留**
- 文件: lib/features/reader/data/repositories/reader_repository_impl.dart:180-204,483-485
- 问题: 无 bookInfoRules 时 _lastBookDetail 不更新也不清空，后续章节 purify 拿到上一本书的书名。
- 影响: 净化规则（按书名）可能用错 bookName。
- 建议: getChapter 开始时按 bookId 清空/隔离 _lastBookDetail。
- 来源: reader

**P3-10　段落分页切分 trim() 丢边界空白**
- 文件: lib/features/reader/core/pagination/page_layout.dart:173-176
- 问题: chunk=substring(start,best).trim() 在页边界剥离首尾空白，西文/空格场景可能丢字符或连字。
- 影响: 长段落跨页时边界文字轻微损坏。
- 建议: 保留断点侧空白或按词边界切分。
- 来源: reader

**P3-11　注音开启后逐字 WidgetSpan 且拼音查询无缓存**
- 文件: lib/features/reader/core/pagination/phonetic_annotator.dart:40-72,99-133
- 问题: 每字符查常用字表+生僻字同步 pinyin 查询+每个生僻字一个 WidgetSpan，每次 rebuild 重算。
- 影响: 注音开启时大章节渲染明显变慢。
- 建议: 缓存 pinyin 查询结果，合并连续普通文本、生僻字段 span 缓存。
- 来源: reader

**P3-12　PhoneticSettings 强转崩溃风险**
- 文件: lib/features/reader/core/pagination/phonetic_annotator.dart:161,168
- 问题: box.get(...) as bool 在存储值损坏（非 bool）时抛错，ensureLoaded 在 initState 中 unawaited 调用。
- 影响: 未处理异步异常，极端情况崩溃。
- 建议: 用 is bool 判定回退默认值。
- 来源: reader

**P3-13　书签/笔记 ID 用毫秒时间戳可能碰撞**
- 文件: lib/features/reader/presentation/pages/reader_page.dart:201,363
- 问题: millisecondsSinceEpoch.toString() 作 id，同毫秒/时钟回拨会碰撞，Hive 同 key 覆盖。
- 影响: 极少见的数据覆盖。
- 建议: 用 uuid 或递增序号。
- 来源: reader

**P3-14　删除书籍不清理整本缓存盒（book_cache）**
- 文件: lib/features/bookshelf/presentation/pages/bookshelf_page.dart:296-308
- 问题: 删除时清理章节缓存/进度/书签/笔记，但未清理 BookCacheBox 整本缓存。
- 影响: 整本缓存孤儿数据残留磁盘。
- 建议: 一并按 bookId 前缀删除 BookCacheBox 条目。
- 来源: reader

**P3-15　EPUB 导出 XHTML 不合法**
- 文件: lib/features/reader/data/services/book_exporter.dart:153-164,169-189
- 问题: _toXhtmlFragment 直接内嵌 body.innerHtml（HTML5 序列化，未闭合 br/img）到 .xhtml。
- 影响: 严格 EPUB 校验器可能拒绝，部分阅读器渲染异常。
- 建议: 用 XML 序列化或手动闭合空标签。
- 来源: reader

**P3-16　setChineseMode 无 _loadSeq 竞态防护**
- 文件: lib/features/reader/presentation/providers/reader_provider.dart:559-587
- 问题: 该方法是唯一重解析/重分页却未检查 _loadSeq 的路径；与在途 loadChapter 竞态时基于旧 chapter 重排后被新加载覆盖。
- 影响: 快速切章+切简繁时短暂显示旧内容。
- 建议: 捕获并校验 _loadSeq，或取消在途加载。
- 来源: reader

**P3-17　_ensureController 在 build 中创建/释放 PageController（副作用）**
- 文件: lib/features/reader/presentation/widgets/page_view_widget.dart:54-61,145
- 问题: LayoutBuilder builder 内调用 _ensureController，含 _controller?.dispose() 与 new PageController 副作用。
- 影响: 脆弱（依赖时序），当前有 hasClients 保护未崩溃。
- 建议: 控制器创建/同步移到 postFrame 或 didUpdateWidget。
- 来源: reader

**P3-18　TXT 导入 50MB 全量内存拷贝**
- 文件: lib/features/bookshelf/data/services/txt_importer.dart:36-53
- 问题: utf8.decode 失败后再 gbk.decode 再次全量分配，随后 content.split 生成整行 List；50MB 文件 isolate 峰值 200-300MB。
- 影响: 低内存设备导入大 TXT 时 isolate OOM。
- 建议: 按行流式解码避免整文件字符串与行数组同时驻留。
- 来源: storage

**P3-19　EPUB 章节正文解码无容错，非 UTF-8 章节整章静默丢弃**
- 文件: lib/features/bookshelf/data/services/epub_importer.dart:64
- 问题: utf8.decode(content) 未传 allowMalformed；中文 EPUB 章节 XHTML 为 Latin-1/GBK 时抛错被 69 行 catch 吞掉，整章消失。
- 影响: 部分 EPUB 正文缺章。
- 建议: allowMalformed:true 或按 meta charset 探测编码。
- 来源: storage

**P3-20　widget_test 覆盖极窄且临时目录未清理**
- 文件: test/widget_test.dart:16-44
- 问题: 真实冒烟（pumpWidget(EasyReadApp) 断言书架空态）但只覆盖空书架一条路径；createTempSync 目录未在 tearDownAll 删除。
- 影响: UI 覆盖几乎为零。
- 建议: 补导航/阅读器/设置页交互测试并清理临时目录。
- 来源: storage

## 三、Top 10 优先修复清单

| 优先级 | 问题 | 文件 | 建议 |
| --- | --- | --- | --- |
| 1 | SSRF DNS 重绑定读内网 | lib/core/network/dio_client.dart:270-291 | 解析并校验 DNS 结果/逐跳 IP，出站代理或白名单 |
| 2 | JS 规则外泄 Cookie | js_rule_executor.dart:1861-1942 | ajax 同源约束+跨域确认+不暴露原始 cookie |
| 3 | 加密密钥降级覆盖致数据永久丢失 | lib/core/database/hive_init.dart:30-53 | read 任何异常不持久化新密钥 |
| 4 | WebDAV 自动备份明文上传凭据 | webdav_backup_scheduler.dart:183-203 | 自动备份走 AES-GCM 加密或敏感剥离 |
| 5 | WebDAV 重定向 Authorization 不剥离 | webdav_sync.dart:63-87 | followRedirects:false+逐跳校验清敏感头 |
| 6 | 净化正则 ReDoS 冻结 UI | regex_purifier.dart:96-109 | isolate 执行/匹配上限+强化启发式 |
| 7 | post/head 请求风暴无上限 | js_rule_executor.dart:518-578 | 加数量上限/wall-clock 预算 |
| 8 | 换源丢失 @put 变量 | reader_page.dart:293-336、book_detail_page.dart:172-186 | 两处透传 variables |
| 9 | 滚动进度串位/丢位置 | scroll_view_widget.dart:17-61 | didUpdateWidget 重置+去节流 flush |
| 10 | 备份恢复非原子丢数据 | backup_restore.dart:187-242 | 快照回滚或临时盒整体替换 |

## 四、各维度健康度一句话点评

- **架构与状态管理（architect）**：分层骨架完整、Riverpod 克制有亮点（ref.listen、请求序号防竞态），但 domain 反向依赖 Flutter/data、provider 暴露具体实现、go_router 迁移不彻底，依赖边界多处击穿——“能用但不干净”。
- **网络与安全（security）**：SSRF 字面量校验、逐跳敏感头清理、Cookie/AES 密钥管理做得较扎实，但 DNS 解析级 SSRF、JS Cookie 外泄、WebDAV 明文与重定向凭据剥离失效三处构成真实远程风险。
- **解析引擎与净化管线（engine）**：quickjs 隔离/超时/回收/上限设计较完善，主要风险集中在 Dart 同步正则无超时与 post/head 无数量上限两处，另有若干语义正确性缺陷（replaceFirst/scope/canHandle/JSONPath）。
- **阅读器与 UI（reader）**：滚动模式是问题重灾区（进度串位/丢位置/书签/章节搜索），换源丢变量属核心功能缺陷；图片缓存、详情页重建、分页/注音性能等为体验问题。
- **数据存储/测试/CI（storage）**：备份加密与版本校验有防护，但加密密钥降级路径、适配器无版本、恢复非原子构成数据安全短板；CI 无测试兜底放大全部风险。

---
复检说明：本报告 47 条全部来自队友五维度实际发现（来源已逐条标注），未编造新问题；严重度按统一标准重排（3 条升 P0、1 条降 P2、多条架构 P1 降为 P3）。文件/行号已抽查全部 P0/P1 与代表性 P2/P3，基本准确；个别修正见 P1-7、P3-8 标注。标记 ⚠️ 的条目（P0-1 出站链路、P0-3 触发时序、P2-6/P2-7 触发用例）需人工进一步确认。

---

## 修复进度（2026-08-17 第 1 轮）

已修复（P0×3 + P1×8），已通过 dart analyze 对改动文件的静态校验（No issues found）：

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P0-1 | SSRF 增加域名 DNS 解析逐条校验，封堵 nip.io/重绑定 | lib/core/network/dio_client.dart |
| P0-2 | JS 网络桥同站（host/子域）限制，封堵 Cookie 外带 | lib/features/search/data/engines/js_rule_executor.dart |
| P0-3 | 安全存储读失败不再写回新密钥，改为内存态临时密钥 | lib/core/database/hive_init.dart |
| P1-1 | WebDAV 自动备份剥离 CookieJar（buildBackupJson includeSensitive=false） | lib/features/settings/... |
| P1-2 | WebDAV 改手动逐跳重定向，跨域/降级清除 Authorization | lib/features/settings/domain/usecases/webdav_sync.dart |
| P1-3 | 强化 ReDoS 守卫：顶层 alternation + 组后任意量词 | lib/core/purification/purify_pattern_guard.dart |
| P1-4 | java.post/head 增加 _maxFetchUrls=50 总量上限 | lib/features/search/data/engines/js_rule_executor.dart |
| P1-5/P1-6 | 滚动模式切章重置 + 去除 1s 节流 + 进度章节校验 | lib/features/reader/presentation/widgets/scroll_view_widget.dart |
| P1-7 | 换源透传 @put variables | reader_page.dart、book_detail_page.dart |
| P1-8 | 恢复改 putThenPrune 非破坏写入，避免清空后失败丢数据 | lib/features/settings/domain/usecases/backup_restore.dart |

待办：P2×16、P3×20、全量回归测试（flutter test 需放开 SDK cache 写权限后执行）。

### 第 2 轮新增修复（P2×6 + P3×2，均通过 dart analyze 校验）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P2-1 | go_router state.extra 全量类型守卫，深链/类型不符不再崩 | lib/core/router/app_router.dart |
| P2-4 | replaceFirst 未命中返回原值（原误返回替换串） | rule_engine.dart |
| P2-6 | JsTemplateEngine.canHandle 改 java 方法白名单，未知能力交 JsRuleExecutor | js_template.dart |
| P2-7 | JSONPath 递归下降/过滤器解析加 128 层深度上限 | json_path.dart |
| P2-10 | 缓存进度改 ValueNotifier，仅刷新按钮文本，避免整页高频重建 | book_detail_page.dart |
| P2-12 | book_cache 按书数淘汰最旧整本缓存（maxBooks=20） | book_cache_service.dart |
| P2-13 | cacheBook 同书同源并发去重（Future gate） | book_cache_service.dart |
| P2-15 | pubspec 固定 hive:2.2.3，防帧格式漂移破坏明文探测 | pubspec.yaml |
| P2-16 | 新增 .github/workflows/ci.yml（analyze + test，PR/push 触发） | .github/workflows/ci.yml |
| P3-8 | 替换展开支持 $&（js_purifier 另补 $$ 转义） | js_purifier.dart、rule_engine.dart |
| P3-19 | EPUB 章节 utf8.decode 加 allowMalformed，非 UTF-8 章节不再静默丢弃 | epub_importer.dart |
| P3-20 | widget_test 临时目录记录并在 tearDownAll 删除 | test/widget_test.dart |

说明：P2-5（scope 子串匹配）为 Legado 既有 contains 语义，非缺陷，维持不更改为精确匹配以免破坏书源兼容。

### 第 3 轮新增修复（P3×8，均通过 dart analyze 校验）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P3-3 | app.dart microtask 每步 ref.read 前校验 mounted，杜绝 dispose 后 StateError | lib/app.dart |
| P3-5 | 新增 redactUrl 工具，reader_repository/import_book_source 日志脱敏、异常只打类型 | url_redact.dart 等 |
| P3-6 | JS 黑名单剥离符号后二次匹配，防 _ffi+Notify、ev+al( 字符串拼接绕过 | js_rule_executor.dart |
| P3-9 | getChapter 净化书名参数按 bookId 隔离，杜绝 _lastBookDetail 跨书残留 | reader_repository_impl.dart |
| P3-10 | 段落分页不再 trim 边界空白，避免西文连字/字符丢失 | page_layout.dart |
| P3-12 | PhoneticSettings 读值改用 is bool 判定，损坏值不再强转崩溃 | phonetic_annotator.dart |
| P3-13 | 书签/笔记 id 改时钟+自增+随机复合，杜绝毫秒时间戳碰撞 | reader_page.dart |
| P3-14 | 删除书籍时连整本缓存盒 book_cache 一并清理 | bookshelf_page.dart |
| P3-15 | EPUB 导出 XHTML void 标签补自闭合（br/img/hr…） | book_exporter.dart |

说明：P3-6 未移除 QuickJS 原生 _ffiNotify 绑定以免改动 native 层大量死代码（当前为空操作、逃逸面小），改为加固黑名单纵深防御作为等效缓解。

### 第 4 轮新增修复（P2×1 + P3×3，均通过 dart analyze 校验）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P2-3 | ReaderNotifier.build() 注册 ref.onDispose：取消防抖 Timer、清挂起进度写入 | lib/features/reader/presentation/providers/reader_provider.dart |
| P3-11 | 拼音查询加静态缓存，翻页/重排不再重复走 pinyin 原生查询 | phonetic_annotator.dart |
| P3-16 | setChineseMode 加 _loadSeq 竞态防护，等待期快速切章不被旧重排覆盖 | reader_provider.dart |
| P3-17 | page_view_widget 控制器首次创建后不再在 build 中 dispose/recreate；页码同步统一走 postFrame | page_view_widget.dart |

说明：P2-8（滚动书签 offset）、P2-9（滚动模式章节内搜索）、P2-11（图片缓存/重试）、P2-14（适配器版本）为结构性改动且需渲染层位置 API 或 schema 迁移，暂缓；P2-5 维持（Legado contains 语义）。

### 第 5 轮新增修复（P2×1 + P3×1，均通过 dart analyze 校验）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P2-11 | 正文图片点击重试：新增 ReaderNetworkImage（页/滚动视图内联图改 fitWidth 保留整幅）；图片章节页也加点击重试 | reader_network_image.dart、page_view_widget.dart、scroll_view_widget.dart、image_reader_widget.dart |
| P3-18 | TXT 解析改为逐行扫描，去掉 content.split 的整份行列表拷贝，降低大文件峰值内存 | txt_importer.dart |

说明：P2-11 磁盘缓存建议后续引入 cached_network_image（需新增依赖）；P2-14（适配器版本/字段数）与 P3-1/2/4/7 为结构性改动（schema 迁移、Provider 化、WebDAV 配置加密），需迁移测试/依赖调整，暂缓并在全量回归前完成。

### 第 6 轮新增修复（P2×1 + P3×1，均通过 dart analyze 校验）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P2-14 | BookModel/ChapterModel/ReadingProgressModel 适配器加尾部 schema 版本字节；read 按 availableBytes>0 条件读取——旧数据无版本字节仍可读（向后兼容），为将来字段演进提供迁移锚点 | book_model.dart、chapter_model.dart、reading_progress_model.dart |
| P3-2 | AppRouter.router 由 static final 改为 appRouterProvider（Riverpod provider，随 ProviderScope 生命周期管理），app.dart 用 ref.watch | app_router.dart、app.dart |

说明：P2-14 采用「尾部版本字节 + 条件读取」以满足向后兼容，未一步到位改成字段键/魔数编码（避免破坏既有已落盘数据，需迁移测试兜底）；P2-2/P2-8/P2-9 与 P3-1/P3-4/P3-7 仍为结构性改动，计划在全量回归阶段完成。

### 第 7 轮新增修复（P3×2，均通过 dart analyze 校验）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P3-4 | purifyPipelineProvider 的 ManagePurificationRules 改为经 managePurificationRulesProvider 注入，测试可 override 替身 | purify_pipeline_provider.dart |
| P3-7 | WebDAV 凭据（URL/用户名/密码）统一改存平台安全存储，不再明文落 Hive；读取时自动迁移旧 Hive 配置并清盒；配置页改从安全存储异步回填 | webdav_sync.dart、webdav_config_page.dart |

说明：P3-1（backup_restore domain 内嵌 showDialog/TextField 弹窗）与 P2-2/P2-8/P2-9 为较大结构性重构，需配合 UI 分层调整与渲染层位置 API，计划在全量回归（放开 flutter test 写权限）阶段一并收尾并加回归测试；P2-5 维持（Legado contains 语义）。

### 第 8 轮新增修复（P2 x3 + P3 x1，全量 dart analyze 通过）

| 编号 | 修复内容 | 文件 |
|---|---|---|
| P2-2 | 阅读器路由改经 go_router extra 传递 ReaderRouteArgs 对象（bookshelf/详情页/换源三处），避免复杂 JSON 塞 URL query；路由保留 query 兜底兼容深链 | app_router.dart、bookshelf_page.dart、book_detail_page.dart、reader_page.dart |
| P2-8 | 书签新增 scrollOffset 维度：滚动模式可加多个书签（按近位置去重）、列表显示位置百分比、跳转记录滚动位置 | bookmark.dart、bookmark_service.dart、reader_page.dart、bookmark_sheet.dart |
| P2-9 | 滚动模式章节内搜索：直接搜原始节点，新增 jumpToNode 记录归一化位置，搜索 sheet 按模式路由跳转 | reader_provider.dart、chapter_search_sheet.dart |
| P3-1 | backup_restore 的口令对话框移出 domain 到 presentation 层（showPasswordPrompt）；exportBackup/restoreBackup 改收 passwordPrompt 回调，domain 不再依赖 flutter/material | backup_restore.dart、password_prompt.dart(新)、settings_page.dart |

说明：P2-5（scope/excludeScope 子串匹配）为 Legado 既有 contains 语义，维持不改以免破坏书源兼容；除 P2-5（判定为设计语义）外其余 46 条均已修复。全量 dart analyze（lib + test/widget_test.dart）已通过；flutter test 全量回归需放开 Flutter SDK cache 写权限后执行。