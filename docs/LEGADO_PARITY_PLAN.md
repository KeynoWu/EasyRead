# EasyRead 对标 Legado 超越计划（Roadmap v1，2026-09-02）

> 目标：书源兼容性完全对标 legado 3.x（`tmp/legado-master/` 源码快照为行为基准），在易用性/工程质量上超越。
> GPL-3.0 边界：只借鉴机制与语义，不复制代码/正则表达式/资源。
> 基线：main 402bf23，20681 行，48 个测试文件全绿，analyze 0 问题。

## 现状核对结论（2026-09-02，逐项对照 legado 源码）

已落地（无需重做）：
- `@put/@get` 变量体系（rule_variables.dart + BookDetailService.variablesJson 持久化 + 目录/正文透传）
- 目录 `nextTocUrl` / 正文 `nextContentUrl` 翻页循环（20 页上限 + visited 防环 + 章节去重重排）
- 搜索 `{{key}}/{{page}}` + `URL,{json选项}`(method/body/charset) + loginUrl POST + GBK
- 按源串行限速（rate_limit_interceptor，source_id 队列）+ 重试 + UA + Cookie
- `concurrentRate` 源级限流（C1，2026-09-02 落地）：`N/M` 滑窗 / 单数字间隔，
  决策只读+放行时刻提交窗口，同源串行链，未配置回退全局 minIntervalMs；6 个单测
- 正文 `contentUrl` 空时回退 `detailUrl`（legado 语义）
- 净化 20 条内置规则 + `@js:` 替换（quickjs）+ scope/excludeScope 字段（存储层）
- quickjs 完整引擎（macOS/Android 原生，iOS 模板降级）+ 36 个 `java.*` API
- isVolume 卷章、批量检测并发 6、聚合搜索 worker 池

真实缺口（本计划的主体）：
1. 规则文法：`%%` 交叉合并、JSoup `||` 短路、`##` 第4段（仅首匹配）、bookList `-`/`+` 前缀、
   `<page,N>` 多页占位符、`[a:b:c]` 范围/步长/`[!i]` 排除索引、`textNodes`/`all` 语义核对
2. jsLib 源级共享脚本作用域（legado shareScope：源内 JS 函数互调、导入脚本）
3. 净化规则 scope/excludeScope 实际生效 + 超时自动禁用（RegexTimeout 语义）
4. JS API 长尾（80 vs 36）：cache/file/archive 类、webView 类、queryTTF 类按需补
5. 规则执行统一为"段列表归约"（消特判，AnalyzeRule 分发模型）
6. 搜索 `bookList` 空时按详情页解析（单本直连源）；正则管道分析器
7. 超越项：检测/订阅/测试体验、性能（Isolate 解析）、兼容性度量

## 里程碑

### M-A 文法补齐（目标：主流书源集解析通过率 ≥95%）
- A1 `##` 第4段语义 + bookList `-`/`+` 前缀（search/catalog 两处）
- A2 JSoup `||` 短路 / `%%` 交叉合并（selector_engine + json_path 两端）
- A3 索引 DSL：`[a:b:c]`/`[!i]`/负索引（rule_engine cascade 步）
- A4 `<page,N,...>` 翻页占位符 + `page` JS 绑定进 js_rule_executor
- A5 `textNodes`（子文本节点 \n join）语义核对与修正
- 验收：XIU2 71e56d4f（22源）+ 源仓库 top30 源批量检测 + e2e 断言目录/正文非空；
  新增单测每项 ≥3 个（含 legado 文档示例规则）

### M-B 引擎统一（段列表归约重构）
- B1 抽取 RuleSegment（mode/ruleStr/regex/replacement/firstOnly/putMap/getList）
  与 RulePipeline（段归约执行），search/reader/catalog 全部改走统一入口
- B2 jsLib：书源 rules['jsLib'] 注入 quickjs 全局（源级 shareScope 等价），
  JsRuleExecutor 增加 importScript 缓存
- B3 消灭 catalog_parser/js_rule_executor 内的规则特判（grep @put/@get 直接处理处清零）
- 验收：现有 48 文件测试全绿无修改（行为不变证明）；`grep -c "@put:" lib/` 归零（仅 rule_variables）

### M-C 稳定性与净化（对标 legado 防御体系）
- C1 (完成 2026-09-02) `concurrentRate` 接入 rate_limit_interceptor：
  N/M 滑窗 + 单数字间隔，extra['concurrent_rate'] 注入，6 单测全绿；
  待办：真实 N/M 源 20 并发无 403 验证（随批量检测回归）
- C2 净化规则 scope/excludeScope 生效 ✅(2026-09-03,含 advisor 复查修复):
  - scope 匹配:**双向 contains**(scope 项包含书名/源名/源 URL,
    或书名/源名/源 URL 包含 scope 项)。与 legado 严格 SQL
    (`scope LIKE '%name%'`,scope 整串须含完整书名)的偏差是有意取舍:
    ①`target.contains(item)` 是 EasyRead 旧实现既有行为,收紧会删存量行为;
    ②legado 主场景(scope 填短名'凡人修仙传',书名'凡人修仙传(精校版)')
    在严格方向失配,双向是严格语义的**超集**(legado 能匹配的双向都能),
    代价是部分重叠名('书A'命中'书A续集')较宽——测试已固定该语义。
    书名/源名任一为 null 时该维度跳过,不因空串恒真全量命中。
  - 匹配目标:书名 + 源名 + 源 URL(bookSourceUrl;legado origin 即 URL)。
  - 超时:默认 3000ms(legado getValidTimeoutMillisecond 语义,
    timeoutMillisecond<=0→null→回落默认)。Dart 规则 Isolate 逐条执行
    (卡死正则不阻塞事件循环),**worker 探活**:spawn 失败/worker 异常退出
    → 主 isolate 同步重试(基础设施故障不误判超时、不误禁规则);
    仅 worker 存活却超时才触发 onRuleTimeout → 会话禁用 + Hive 持久化
    (enabled=false,disableRule 幂等)。
  - JS 规则:规则级 deadline(timeoutMs 覆盖匹配收集+全部替换脚本,
    先于 quickjs 指令中断触发,超时回调真实可达)。超时回收:**先
    engine.dispose() 100ms 优雅协议回收,失败才硬杀**;forceDispose
    先 kill 后 close 端口(third_party fork 行为变更,js_rule_executor
    共用此路径——kill 对 FFI 卡死 isolate 的退场要等指令中断,直接硬杀
    会让宿主等待其退场,搜索链路排查同类挂起时先查这里)。
  - _buildPurifier 透传 id/timeoutMs(映射断言测试堵回归)。
  - 测试:purify_rules_test 新增 12 个 C2 用例,405 全绿 + analyze 0。
- C2.1(审查遗留 nit)jsLib JSON 形式的 URL 值:legado 先抓 URL 内容
  再执行,EasyRead 当脚本字面 eval;且 JSON 解析失败静默返空串无痕迹。
  量级低(URL 形式罕见),修复需 jsLibScript 异步化(网络依赖贯穿),
  随 C3 或下次书源会话处理。
- C3 jsLib/模板执行隔离：失败源熔断（单源 JS 异常计数 → 短时降级，参照现有 quickjs 降级）

### M-D 超越项（legado 没有或做得差的）
- D1 兼容性度量看板：批量检测历史 + 源通过率趋势（基于现有 book_source_test_store）
- D2 Isolate 并发解析（JSON/HTML 解析移出主 isolate，搜索吞吐翻倍目标）
- D3 书源市场：URL 一键导入 + 检测报告卡片（通过率/耗时/失败原因归类）
- D4 规则智能修复：解析空结果时自动尝试常见别名（contentUrl/bookUrl 等已有，
  扩展为失败原因驱动的 retry 矩阵）

## 执行顺序与节奏
A1→A5（1 周）→ B1→B3（1 周）→ C1→C3（3 天）→ D 按需。
每项独立 PR：文法项带单测+真实源样本；重构项带"测试不变"证明。

## 风险与红线
- 不搬 legado 代码（GPL）；正则/规则示例自行构造或来自书源 JSON（用户数据）。
- 重构期冻结新文法（避免 B1 与 A 系列冲突）；B1 前先落 A 系列回归样本集。
- iOS 无 quickjs：所有 JS 依赖路径必须有模板/正则降级与测试断言。
