# 规则引擎对照研究（Legado 3.x ↔ EasyRead）
基准：L/=tmp/legado-master/.../io/legado/app/（2025-02 快照，反编译 APK 交叉确认一致）；E/=EasyRead/lib/

## 1. 段列表归约模型启示（Legado 三层：splitSourceRule→段 mode 判定→后端内 &&/||/%% 归约）
- Legado 允许 JS 段出现在任意位置（JS_PATTERN 分割，L/AnalyzeRule.kt:470-480）；EasyRead isJsRule 只查规则开头（E/rule_parser.dart:67-70）→ 混合段（CSS 在前 JS 在后）不工作。
- 分隔符判定：Legado 最左分隔符定组合类型（L/RuleAnalyzer.kt:176-191）；EasyRead 固定优先级 %%>||>&&（E/rule_parser.dart:76-78）→ 混合规则 a&&b||c 切分不同。
- ||短路/%%索引合并/&&拼接 WIP 已覆盖且语义一致（E/rule_engine.dart:287-324, 57-86 == L/AnalyzeByJSoup.kt:104-122）；唯一回归是 JSONPath 引擎把 && 当首非空（E/json_path.dart:19-24）。

## 2. 文法特性差距清单（✅ WIP已覆盖 / ◐ 部分 / ✗ 未覆盖）
1. ||短路（首个非空即止）：✅ E/rule_engine.dart:288-294, 302-308 == L/AnalyzeByJSoup.kt:104-107。
2. %%索引交叉合并（i 遍历首结果，各结果取 result[i]）：✅ E/rule_engine.dart:312-322 == L/AnalyzeByJSoup.kt:110-117。
3. bookList -/+ 前缀（搜索/发现，- = 结果倒序）：✅ E/search_repository_impl.dart:170-190, 378-397 == L/BookList.kt:80-86, 126-129。
4. chapterList -/+ 前缀（目录）：✗ E/catalog_parser.dart:133-143 未剥前缀，-chapterList 判无效 CSS→0 章（L/BookChapterList.kt:49-56, 119-128）。
5. <page,N,...> 翻页占位符：◐ 已实现 E/rule_template.dart:23-31，但 page=null→按第1页，Legado 保留占位符（L/AnalyzeUrl.kt:192-202）。
6. JSON 响应默认 JSONPath 模式：✗ L/AnalyzeRule.kt:533-536（isJSON→无前缀规则也走 Json）；E/rule_parser.dart:27-30 只认 $ / @json: 前缀，extractElements 无 JSON 回退（E/rule_engine.dart:45-50）。
7. 纯 {{js}}/@get: 字段规则（HTML 元素上下文）：✗ E/rule_engine.dart:130-136 落 CSS 返 null；Legado Mode.Regex 替换 trick（L/AnalyzeRule.kt:552-558, 624-683, 290）。
8. ruleContent.replaceRegex：✗ EasyRead 只认 ["pat","rep"] 或 pat||rep（E/content_extractor.dart:185-207）；Legado 是完整规则作用于全文（L/BookContent.kt:138-143），纯 ## 规则跳过后端只替换（L/AnalyzeRule.kt:279）→ 导入源替换规则被静默忽略。
9. 规则中段 JS（非开头 @js:/<js>）：✗ E/rule_parser.dart:67-70；Legado 任意位置分割（L/AnalyzeRule.kt:470-480）。
10. @put/@get 变量、负索引 len+n：✅ E/rule_variables.dart:13-63, E/selector_engine.dart:463, 517 == L/AnalyzeRule.kt:390-411, 704-730 / L/AnalyzeByJSoup.kt:334-335。（P2 余：HTML unescape L/AnalyzeRule.kt:300-306 ✗；isUrl 空→baseUrl+去重 L/AnalyzeRule.kt:307-313, 218-229 ◐；{$ rule L/AnalyzeByJSonPath.kt:41 ✗；checkKeyWord L/BookSource.kt:207-213 ✗）

## 3. URL 规则机制差距
1. nextContentUrl 缺 nextChapterUrl 终止：✗ E/reader_repository_impl.dart:414-445（仅 visited+20页上限）；Legado nextUrl==nextChapterUrl 时 break 防跨章（L/BookContent.kt:83-86）。
2. 全 JS URL（searchUrl=@js:... 整串）：✗ E/search_repository_impl.dart:50-66 只做 {{}} 替换+插值；Legado analyzeJs 整串执行（L/AnalyzeUrl.kt:148-171）。
3. URL,{json} 选项仅 method/body/charset：✗ E/search_repository_impl.dart:768-795；Legado 另有 headers/js(改写url)/type/retry/webView/serverID（L/AnalyzeUrl.kt:223-240, 600-752）。
4. 多 URL next 并发拉取：✗ E/catalog_parser.dart:244-258 只取首个；Legado mapAsync 并行（L/BookChapterList.kt:89-114, L/BookContent.kt:110-135）。concurrentRate 已对齐 ✅ E/rate_limit_interceptor.dart:11-114 == L/ConcurrentRateLimiter.kt:18-124。

## 4. XPath/JSONPath 覆盖差距（Legado：JsoupXpath 2.5.3 近全 XPath1.0、Jayway json-path 2.9.0，L/libs.versions.toml:22,26）
1. XPath ✅ 已覆盖：//tag、/tag 直接子代、[@attr]、[@attr="v"]、contains、[N]（1基+负）、position() 四向比较、and、尾部 /@attr、/text()（E/selector_engine.dart:52-273）。
2. XPath ✗ P1 缺失：last()、or/not、!=、starts-with()（E/selector_engine.dart:144-221 不识别→整规则空结果）。
3. XPath ✗ P2 缺失：substring/string-length/count/number、轴（parent/兄弟/祖先）、| 并集、. /..；[ 扫描用 indexOf(']') 遇属性值含 ] 误切（E/selector_engine.dart:155）。
4. JSONPath ✅ 已覆盖：$、.key、['key']、..key、[*]、[N≥0]、[?(expr)]（== != > >= < <= && || () 字面量、@.a.b、裸@）（E/json_path.dart:16-180, 338-540）。
5. JSONPath ✗ P1：顶层 || 组合（Legado 首非空，L/AnalyzeByJSonPath.kt:35, 62-64）不识别（E/json_path.dart:143-180）；&& 语义偏差——Legado 全非空拼接（L/AnalyzeByJSonPath.kt:142-168），EasyRead 取首个非空（E/json_path.dart:19-24）；负索引 [-1] 不支持（E/json_path.dart:58-63）。
6. JSONPath ✗ P2 缺失：!/not、~= 正则、length()/contains()、并集 [1,2]、切片 [1:3]、..* 递归通配。

## 5. 索引 DSL 对照结论（L/AnalyzeByJSoup.kt:293-511 vs E/rule_parser.dart:231-379 + E/selector_engine.dart:509-537）
1. ✅ 一致：[int]±、[a,b,c] 按规则序去重、[a:b]、[a:b:c]（正步长）、[!...] 排除、children.N、class./id./tag./text. 前缀、越界单索引跳过、范围端点 clamp。
2. ✗ 相反（最重要）：legacy . /! 中 ':' 语义——Legado 是离散索引分隔符（tag.div!0:3=排除{0,3}，L/AnalyzeByJSoup.kt:283-284 注释+491-501 代码）；EasyRead 解析为范围 {0,1,2}（E/rule_parser.dart:324-346，注释自称与 Legado 一致，实际相反）。
3. ✗ 端点省略：Legado 支持 [:3]（start=0）、[3:]（end=len-1）（L/AnalyzeByJSoup.kt:431-453）；EasyRead 正则要求两端齐备，整个索引集被拒→按无索引取全部（E/rule_parser.dart:359-360）。
4. ✗ 逆序范围/负步长：Legado [5:2]（end<start）降序 5,4,3,2（L/AnalyzeByJSoup.kt:370），负步长转 len+step（:366-367）；EasyRead [5:2]→空（E/selector_engine.dart:525-528），负步长→降序（:529-533）。

## 6. 总体建议（按优先级）
P0-1 replaceRegex 改为完整规则语义（纯 ## 规则=跳过后端只替换，L/AnalyzeRule.kt:279）——现状 Legado 源替换规则被静默丢弃（E/content_extractor.dart:185-207）。
P0-2 nextContentUrl 循环加 nextChapterUrl 终止（E/reader_repository_impl.dart:414-445，参照 L/BookContent.kt:83-86），防下一章内容混入。
P0-3 chapterList -/+ 前缀（E/catalog_parser.dart:133-143 复用 E/rule_parser.dart:85-95，解析后 reverse，同搜索侧 E/search_repository_impl.dart:187-190）。
P1-4 JSONPath &&→全非空拼接 + 顶层 || 首非空（E/json_path.dart:19-24, 143-180，参照 L/AnalyzeByJSonPath.kt:56-121）。
P1-5 JSON 响应默认 JSONPath 模式（E/rule_engine.dart:45-50 加响应检测，参照 L/AnalyzeRule.kt:533-536）。
P1-6 元素上下文纯 {{js}}/@get: 字段规则先模板插值再落回管线（E/rule_engine.dart:93-149，参照 L/AnalyzeRule.kt:552-558, 624-683）。
P1-7 全 JS URL + URL,{json} headers（E/search_repository_impl.dart:50-66, 768-795，参照 L/AnalyzeUrl.kt:148-171, 223-225）；XPath 补 last()/or/!=/starts-with（E/selector_engine.dart:144-221）。
P1-8 索引 DSL 三处对齐：legacy : 离散语义、[:3]/[3:] 省略端点、end<start 降序（E/rule_parser.dart:324-379, E/selector_engine.dart:509-537）。
P2 长尾：规则中段 JS、HTML unescape（L/AnalyzeRule.kt:300-306）、{$ rule（L/AnalyzeByJSonPath.kt:41）、多 URL next 并发、JSONPath 负索引/并集/切片/~/length、URL js/retry、checkKeyWord（L/BookSource.kt:207-213）。
不值得学：RuleAnalyzer 字符级状态机（L/RuleAnalyzer.kt:165-298，E/rule_parser.dart:161-215 引号/括号感知拆分已等价且更可读）；ConcurrentRateLimiter 的 synchronized 锁（E/rate_limit_interceptor.dart:17-37 串行链+窗口已等价）；WebView/BackstageWebView（L/AnalyzeUrl.kt:347-378）；QueryTTF 字体解密（ROI 极低）；reGetBook/refresh*（L/AnalyzeRule.kt:791-835，依赖 Room，换源已覆盖）；serverID 多服务器（L/AnalyzeUrl.kt:239, 737-743）；RuleBigDataHelp 大变量文件层（Hive 已覆盖）。
