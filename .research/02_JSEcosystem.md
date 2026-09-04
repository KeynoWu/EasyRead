# JS 生态对照研究（Legado 3.x ↔ EasyRead）· 精要版
路径缩写：[L]=legado-master/app/src/main/java/io/legado/app/（2025-02 快照）[LR]=legado-master/modules/rhino/src/main/java/com/script/ [D]=legado_decompiled/sources/（release 反编译）[E]=EasyRead/（lib 下相对路径）
前提：Legado 的 `java` 绑定是 AnalyzeRule 实例（[L]model/analyzeRule/AnalyzeRule.kt:737），java.* = AnalyzeRule 自有方法 ∪ JsExtensions（978 行）∪ JsEncodeUtils（495 行），去重约 97 个名；另有 cookie(6)/cache(13) 对象与 source/book/chapter/src/nextChapterUrl/rssArticle 绑定。EasyRead 现实现 38 个 java.* + cookie 4 方法 + source.getKey 桩（[E]lib/features/search/data/engines/js_bridge.dart）。

## 1. java.* API 缺口清单（12 条：API | Legado 语义:行号 | 优先级）
1. md5Encode16 | Legado=md5 中段 16 位 substring(8,24)（[L]utils/MD5Utils.kt:22-25，JsEncodeUtils.kt:22）| EasyRead 误取前 16 位（js_bridge.dart:741）→ 签名类源全错 | P0
2. java.get | 1 参=变量读取+特殊键 bookName/title（[L]AnalyzeRule.kt:715）；2 参=网络 GET 无重定向（[L]help/JsExtensions.kt:359）| EasyRead 两参皆当 DOM 查询，输入变量未注入 JS、跨遍 put 不可读 | P0
3. java.post | 同步返回含 body 的 Response（[L]help/JsExtensions.kt:401）| EasyRead body 恒 ''（js_network.dart:135-159 只取响应头）→ 读 POST 体源全失效 | P0
4. ajax 错误语义 | 异常返回 stackTraceStr 字符串，JS 可判失败（[L]AnalyzeRule.kt:783；JsExtensions.kt:103-111 runBlocking 同步）| EasyRead 返回 ''，与空页面不可分（js_network.dart:47）；且同站限制 Legado 没有 | P0
5. timeFormat | 1 参、默认 "yyyy/MM/dd HH:mm" 本地时区（[L]JsExtensions.kt:504，AppConst.kt:39-41）| EasyRead 是 2 参、默认 "yyyy-MM-dd HH:mm:ss"（js_crypto.dart:447-461）| P0
6. java.cache 对象 | put(key,val,ttl秒)/get/getInt/getLong/getDouble/getFloat/getByteArray/delete，内存 LRU 50MB+DB 持久、0=永久、全局扁平 key（[L]help/CacheManager.kt:30/57/69-111）| 完全缺失；书源存 token 最高频 | P0
7. connect / ajaxAll | StrResponse(status/header()/cookies()/body)，并发数组返回（[L]help/JsExtensions.kt:136/149/117）| 缺失 | P1
8. des* 单 DES | Android JCE 可用（[L]help/JsEncodeUtils.kt:284-318）| pointycastle 3.9.1 仅 DESede 无单 DES，symmetricProcess 恒返回空（js_crypto.dart:321-323）| P1（纯 Dart DES 或显式报错）
9. getElements/getElement 动态选择器 | List<Element> 带 .html()/.text()/.attr()，规则管线可 JSON/正则（[L]AnalyzeRule.kt:355/320）| EasyRead 仅字面量选择器（记录遍静态提取），运行时拼接→空（js_rule_executor.dart:29 自认）；getElement 返回字符串非对象 | P1
10. cookie/getCookie | 二级域名归一化、4096 上限、session 合并（[L]help/http/CookieStore.kt:52-75）| EasyRead 原始 URL 为 key 无归一（js_bridge.dart:521-526），reader 正文流未传 cookies（content_extractor.dart 无 cookies 参数）| P1
11. file/zip 类 | downloadFile/readFile/readTxtFile/deleteFile/getZipStringContent，全部沙箱在 externalCache（[L]help/JsExtensions.kt:312/566/574/594/668，头注释 :77-79）| 缺失 | P2
12. toURL / getWebViewUA / androidId / log 可见输出 | JsURL 对象、默认 UA、设备 ID、调试日志（[L]help/JsExtensions.kt:908/545/959/933）| 缺失，log 为 no-op | P2
长尾未实现（P3 或不做）：queryTTF/replaceFont（字体反爬）、webView/webViewGetSource/webViewGetOverrideUrl、startBrowser/startBrowserAwait/getVerificationCode、tripleDES* 4 个、createAsymmetricCrypto/createSign、utf8ToGbk、digestBase64Str、base64 flags/charset 变体、strToBytes/bytesToStr、hexDecodeToByteArray、un7z/unrar、book/chapter/src/nextChapterUrl 绑定、reGetBook/refreshTocUrl。

## 2. jsLib 机制
1. Legado：key=md5(jsLib)，scopeMap=WeakReference<Scriptable>，脚本只评估一次；JSON 形式 {名: 脚本|绝对URL}，URL 用 okHttpClient 下载 + ACache 磁盘缓存（cacheDir/shareJs）；注入=规则 scope.prototype=共享 scope（可被规则遮蔽）（[L]model/SharedJsScope.kt:28-72；AnalyzeRule.kt:750-754）。
2. EasyRead 现状缺陷：jsLib 与每遍规则体拼接重评估（js_rule_executor.dart:137-140 及 :189/:249/:275/:354/:375）→ lib 顶层 const/let 第二次 eval 触发重复声明 SyntaxError → 整规则降级 null；URL 条目被当 JS 代码原样注入 → eval 必败（js_bridge.dart:219-234 无下载/无缓存）；执行间无状态共享（每次新建 engine，弱于 Legado 的 WeakReference 跨规则持久）。
3. 建议（机制级，不抄代码）：lib 按 md5(jsLib) 每 execute() 只 eval 一次且与 body 分离；URL 条目走带超时的同策略抓取+磁盘缓存（失败语义对齐 Legado：抛错使规则失败）；不要学 release 版 topScopeRef（无 jsLib 时 16 次后复用全局 scope，状态泄漏语义含糊）。

## 3. JS↔Dart 通信模型结论
1. Legado：Rhino 纯 JVM 同进程，java 桥=直接 Kotlin 方法调用；ajax/connect/webView 均 runBlocking 同步阻塞、get/head/post 为 Jsoup 同步（无重定向+限频），**无每 eval 硬超时**——中断来自外层协程取消，经 instructionObserverThreshold=10000（每万条指令 ensureActive）与 doTopCall 调用边界检查抛 RhinoInterruptError（[LR]rhino/RhinoScriptEngine.kt:345/358-362/398-403；[LR]rhino/RhinoContext.kt:13-20）。
2. 评估：Legado 并无"更干净的异步模型"可学（本质=同步阻塞+取消）；EasyRead 记录-重放两遍+调用序列一致性校验（不一致降级 null）是 QuickJS 同步 FFI 下的合理妥协且防御性更好，**维持现状**；改进应投向 API 语义（错误串、动态选择器、跨遍变量），而非推翻模型。

## 4. 加密桥语义差异
1. key/iv 处理：Legado(hutool) 长度非法抛异常；EasyRead 静默 md5(key)/md5(iv)/截断兜底（js_crypto.dart:202-216）——合法密钥两者密文一致，非法密钥都失败但模式不同（异常 vs 静默空）。
2. 数据解码自检测：Legado isHexStr 则 hex 否则 base64；EasyRead 要求 hex 且长度≥32 且 %32==0（js_crypto.dart:218-231）→ 1-2 块短密文走不同解码路径，结果分叉。
3. 模式/填充覆盖：EasyRead 仅 ECB/CBC + PKCS5/7/NoPadding + DESede（js_crypto.dart:310-323）；Legado 任意 JCE transformation（GCM/CTR/CFB/OFB/ISO10126…）→ CTR/GCM 类源在 EasyRead 静默失败。
4. 其余对齐点/差异点：hex 小写一致、base64Encode NO_WRAP 一致、encodeURI=URLEncoder(空格→+) 一致；digestHex/HMac 未知算法 EasyRead 静默回退 sha256（js_crypto.dart:110-127）而 hutool 抛异常；HMac 算法名需按 hutool 风格（"HmacSHA256"）兼容。

## 5. cache / file / webView 类取舍
1. java.cache：值得做（P0/P1）——token 持久化是书源高频刚需；做扁平全局 key（勿加源命名空间，Legado 全局共享）+ TTL 秒（0=永久）+ 持久化（Hive 可用）+ 内存 LRU 上限。
2. file/zip：做 P2 子集——downloadFile/readFile/readTxtFile/deleteFile/getZipStringContent（加 archive 依赖），沙箱到 app 缓存目录（对齐 Legado externalCache 沙箱，顺带是安全收益）；un7z/unrar 依赖 libarchive，Flutter 无纯 Dart 对应，明确不做。
3. webView：P3 缓做——flutter_inappwebview 已在依赖里技术上可行，但 WebView 生命周期成本高、任意 URL 加载攻击面大；若做仅同站+用户开关；现阶段文档说明"不支持"即可。
4. startBrowser/getVerificationCode（登录 UI 流程）P3；queryTTF/replaceFont（字体反爬站中等频，纯 Dart 实现 TTF cmap/glyf 解析可做差异化）P3；book/chapter/src 上下文绑定 P3（正文 JS 源需要）。

## 6. 引擎健壮性（中断/限制）
1. Legado：无每 eval 硬超时（仅 reGetBook 等 30min withTimeout）；中断=协程取消+每万条指令/每次 JS→Kotlin 调用边界检查（RhinoInterruptError）；maximumInterpreterStackDepth=1000；ClassShutter 黑名单（Runtime/File/ClassLoader/DB/Settings 等，[LR]rhino/RhinoClassShutter.kt:39-63）；无 JS 堆内存限制；release 新增 evalJS 重入深度≥10 抛 RhinoRecursionError（[D]com/script/rhino/RhinoRecursionError.java、[D]eh/i.java:80-90）。
2. EasyRead：64MB 内存/1MB 栈（[E]third_party/quickjs/lib/src/native_js_engine.dart:230-231）；**H6 已修复**——JS_SetInterruptHandler 已装，3000 万指令预算（每万条回调一次，≈1-3s 中断死循环）（native_js_engine.dart:35-53/:233，quickjs.c:1801）；3s Dart 外部超时+forceDispose 兜底（js_rule_executor.dart:42/:100-111）；timers 默认关 + eval/_ffiNotify/startBrowser 黑名单。结论：保持现状（比 Legado 更严，移动端更安全）；指令预算可按真实源负载再调；可学 Legado 的"错误字符串返回"让 JS 感知失败。

## 7. 总体建议（按优先级）
1. [P0] 修 md5Encode16→中段 16 位（js_bridge.dart:741，substring(8,24)）。
2. [P0] java.get 语义重定义：1 参=变量（注入 Dart 侧 variables 进 __putMap + 特殊键 bookName/title），2 参=同站网络 GET（无重定向）；getElement 返回 Element 风格对象。
3. [P0] java.post 返回真实响应 body（js_network.dart 补 body 抓取）。
4. [P0] ajax/post 网络错误返回 "Exception: <msg>" 式字符串（对齐 stackTraceStr 行为），不再返回 ''。
5. [P0] 实现 java.cache 对象（持久+TTL+扁平 key）。
6. [P1] timeFormat 1 参默认 "yyyy/MM/dd HH:mm"；实现 connect/ajaxAll；des* 单 DES（纯 Dart 实现或显式报错）。
7. [P1] jsLib：每 execute() 只 eval 一次 + URL 条目下载磁盘缓存（消除 const 重声明致整源失败）；cookie 二级域名归一化 + reader 流传入 cookies；getElements 支持动态选择器。
8. [P2] file/zip 沙箱子集；toURL、getWebViewUA、androidId、log→调试输出；digest/HMac 算法扩展（sha384/ripemd160）、base64 flags、strToBytes/bytesToStr、hexDecodeToByteArray、utf8ToGbk、htmlFormat 保留 img；ajax 同站限制改为书源级开关。

## 明确不建议学的
- 弃用函数族 aes*/des*/tripleDES* 全量补齐（createSymmetricCrypto 已覆盖，EasyRead 已有 6 个别名足够）；queryBase64TTF、downloadFile(hex) 弃用变体。
- Legado"无硬超时、靠外层取消"模型——保留 EasyRead 3000 万指令预算+3s 兜底（移动端更安全）。
- release 版 topScopeRef（无 jsLib 时跨规则共享全局状态，语义泄漏）与 compileScriptCache/compileRegexCache（EasyRead 每遍源码不同，收益低）。
- ClassShutter 黑名单式 Java 互操作——QuickJS 无 Java 对象面，结构性更安全，勿引入类 Java 桥。
- cacheFile"永久缓存无大小上限"、getTxtInFolder"读后删目录"等意外行为；startBrowserAwait 等登录流 API（登录 UI 不存在前）。

### 1.3–1.9 已实现但语义有差异（4 条）
1. md5Encode16 | Legado=md5 中段 16 位 substring(8,24)（[L]utils/MD5Utils.kt:22-25；help/JsEncodeUtils.kt:22）| EasyRead 误取前 16 位（js_bridge.dart:741）→ 签名类源全错 | P0
2. timeFormat | Legado 1 参、默认 "yyyy/MM/dd HH:mm" 本地时区（[L]help/JsExtensions.kt:504；constant/AppConst.kt:39-41）| EasyRead 2 参 (time,format)、默认 "yyyy-MM-dd HH:mm:ss"（js_crypto.dart:447-461；js_bridge.dart:426 记录）→ 参数量与默认模式双错位 | P0
3. createSymmetricCrypto | Legado（hutool SymmetricCrypto，[L]help/JsEncodeUtils.kt:40-71；help/SymmetricCryptoAndroid.kt:8-33）：任意 JCE transformation（GCM/CTR/CFB/OFB…）、key/iv 长度非法即抛、decrypt(data) 自动 hex/base64 检测 | EasyRead（js_crypto.dart:304-379）：仅 ECB/CBC + PKCS5/7/NoPadding + DESede；key/iv 非法静默 md5/截断兜底（:202-216）；hex 检测要求 ≥32 且 %32==0（:218-231，短密文分叉）；des* 单 DES 恒空（:321-323，pointycastle 3.9.1 无单 DES）| P1
4. HMac/digest/base64/encodeURI | Legado：HMacHex/HMacBase64 用 hutool HMac("HmacSHA256"…)（[L]help/JsEncodeUtils.kt:466/482）、digestHex 任意摘要算法（:436）、base64Encode 默认 NO_WRAP（help/JsExtensions.kt:467→utils/EncoderUtils.kt:29-31）、encodeURI=URLEncoder（JsExtensions.kt:517-523）| EasyRead：digestHex/HMac 仅 md5/sha1/sha256/sha512、未知算法静默回退 sha256（js_crypto.dart:110-127，Legado 抛异常）；hex 小写、base64 NO_WRAP、URLEncoder(空格→+) 一致（js_bridge.dart:787；js_crypto.dart:412-429）；缺 base64Decode(str,charset/flags) 变体（JsExtensions.kt:445/449）| P2

## 2. jsLib / importScripts 机制
1. Legado：key=md5(jsLib)，scopeMap=WeakReference<Scriptable> 脚本只评估一次；JSON 形式 {名: 脚本|绝对URL}，URL 经 okHttpClient 下载 + ACache 磁盘缓存（cacheDir/shareJs，失败抛错使规则失败）；注入=规则 scope.prototype=共享 scope（规则可遮蔽）（[L]model/SharedJsScope.kt:28-72；AnalyzeRule.kt:750-754；data/entities/BaseSource.kt:253-255）。
2. EasyRead 差距：jsLib 与每遍规则体拼接重评估（js_rule_executor.dart:137-140，:189/:249/:275/:354/:375）→ lib 顶层 const/let 第二次 eval 重复声明 SyntaxError → 整规则降级 null；URL 条目被当 JS 代码原样注入 → eval 必败（js_bridge.dart:219-234 无下载/无缓存）；每次 execute 新建 engine，无跨执行状态共享（弱于 Legado 跨规则持久）。
3. 建议：lib 每 execute() 只 eval 一次（与 body 分离，md5(jsLib) 缓存）；URL 条目带超时抓取 + 磁盘缓存（对齐 SharedJsScope.kt:48-64 语义）；不学 release 版 topScopeRef（无 jsLib 时 >16 次 eval 复用全局 scope，状态泄漏，[D]io/legado/app/model/analyzeRule/AnalyzeRule.java:590-608）。

## 3. JS↔Dart 通信模型结论
1. Legado：Rhino 同进程、java 桥=直接 Kotlin 调用；ajax/connect/webView 全部 runBlocking 同步阻塞（[L]help/JsExtensions.kt:103/137/171；AnalyzeRule.kt:776），get/head/post 为 Jsoup 同步（无重定向+限频，JsExtensions.kt:359-418）；无每 eval 硬超时，中断=外层协程取消 + 每万条指令 ensureActive + doTopCall 调用边界检查 → RhinoInterruptError（[LR]rhino/RhinoScriptEngine.kt:345/358-362/398-403；[LR]rhino/RhinoContext.kt:13-20）。
2. 结论：Legado 没有更干净的异步模型可学（本质=同步阻塞+取消）；EasyRead 记录-重放两遍 + 调用序列一致性校验（不一致降级 null，js_rule_executor.dart:252-256/:376-387）是 QuickJS 同步 FFI 下合理且更防御的妥协 → 维持现状；改进投向 API 语义（错误串/动态选择器/跨遍变量），不推翻模型。

## 5. cache / file / archive / webView 取舍
1. java.cache：值得做（P0）——token 持久化高频刚需；扁平全局 key（Legado 全局共享，勿加命名空间）+ TTL 秒（0=永久）+ Hive 持久 + 内存 LRU 50MB（[L]help/CacheManager.kt:30/57/18-24）。
2. file/zip：做 P2 子集——downloadFile/readFile/readTxtFile/deleteFile/getZipStringContent（[L]help/JsExtensions.kt:312/566/574/594/668，加 archive 依赖），沙箱到 app 缓存目录（Legado 沙箱 externalCache，JsExtensions.kt:77-79/:556-564，顺带安全收益）；un7z/unrar（libarchive）无纯 Dart 对应，明确不做。
3. webView：P3 缓做——flutter_inappwebview 已在依赖（pubspec.yaml）技术上可行，但成本高 + 任意 URL 加载攻击面大；若做仅同站+用户开关；现阶段文档注明"不支持"（[L]help/JsExtensions.kt:170-217 BackstageWebView）。
4. startBrowser/getVerificationCode（登录 UI 流程）P3（[L]help/JsExtensions.kt:224-247）；queryTTF/replaceFont（字体反爬，纯 Dart 实现 TTF cmap/glyf 解析，差异化）P3（JsExtensions.kt:794/850）；book/chapter/src/nextChapterUrl 上下文绑定 P3（AnalyzeRule.kt:736-749）。

## 7. 引擎健壮性（中断/内存限制）
1. Legado：无每 eval 硬超时（仅 reGetBook 30min，AnalyzeRule.kt:796）；中断=协程取消，instructionObserverThreshold=10000（每万条指令 ensureActive）+ doTopCall 边界 → RhinoInterruptError（[LR]rhino/RhinoScriptEngine.kt:345/358-362/398-403；[LR]rhino/RhinoContext.kt:13-20）；maximumInterpreterStackDepth=1000（:346）；ClassShutter 黑名单（Runtime/File/ClassLoader/DB/Settings，[LR]rhino/RhinoClassShutter.kt:39-63）；无 JS 堆限制；release 新增 evalJS 重入 ≥10 → RhinoRecursionError（[D]com/script/rhino/RhinoRecursionError.java；[D]eh/i.java:80-90）。
2. EasyRead：64MB 内存/1MB 栈（third_party/quickjs/lib/src/native_js_engine.dart:230-231）；H6 已修复——JS_SetInterruptHandler 已装，3000 万指令预算（每万条回调，死循环约 1-3s 中断，:35-53/:233；src/quickjs.c:1801）；3s Dart 外部超时 + forceDispose 兜底（js_rule_executor.dart:42/:100-111）；timers 默认关 + eval/_ffiNotify/startBrowser 黑名单（js_bridge.dart:26-48）。保持现状（比 Legado 更严、移动端更安全）；可学 Legado"错误字符串返回"让 JS 感知失败。

## 8. 总体建议（按优先级）
1. [P0] 修 md5Encode16→中段 16 位（js_bridge.dart:741，对齐 MD5Utils.kt:22-25）。
2. [P0] java.get 语义重定义：1 参=变量（注入 Dart 侧 variables 进 __putMap + bookName/title 特殊键，AnalyzeRule.kt:715）；2 参=同站网络 GET 无重定向（JsExtensions.kt:359）；getElement 返回 Element 风格对象（AnalyzeRule.kt:320）。
3. [P0] java.post 返回真实响应 body（js_network.dart:135-159 现 body 恒 ''）。
4. [P0] ajax/post 网络错误返回 "Exception: <msg>" 式字符串（对齐 AnalyzeRule.kt:783 stackTraceStr），不再 ''。
5. [P0] 实现 java.cache 对象（持久 + TTL + 扁平全局 key，CacheManager.kt:30/57）。
6. [P1] timeFormat 1 参默认 "yyyy/MM/dd HH:mm"（AppConst.kt:39-41）；实现 connect/ajaxAll（JsExtensions.kt:136/117）；des* 单 DES（纯 Dart 实现或显式报错，js_crypto.dart:321-323）。
7. [P1] jsLib 每 execute() 只 eval 一次 + URL 条目下载磁盘缓存（消除 const 重声明/URL jsLib 致整源失败，js_rule_executor.dart:137-140）；cookie 二级域名归一化（CookieStore.kt:52-68）+ reader 流传入 cookies；getElements 支持动态选择器（js_rule_executor.dart:29 自认缺口）。
8. [P2] file/zip 沙箱子集（JsExtensions.kt:312/566/668）；toURL/getWebViewUA/androidId/log 调试输出（JsExtensions.kt:908/545/959/933）；digest/HMac 算法扩展 sha384/ripemd160（js_crypto.dart:110-127）、base64 flags、strToBytes/bytesToStr、utf8ToGbk、htmlFormat 保留 img；ajax 同站限制改书源级开关（js_network.dart:186-203）。[P3] queryTTF/replaceFont、webView（同站+开关）、startBrowser 登录流、book/chapter 绑定。
