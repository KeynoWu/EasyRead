## 限流
- Legado concurrentRate：按书源（source.getKey() 键控全局记录表，ConcurrentRateLimiter.kt:11,25）；null/"0"=不限流（BaseSource.kt:32，BookSource.kt:59 默认 null）。
- 单数字=间隔模式：并发 1 + 启动间隔≥N ms；有在途请求时直接等满 N 再轮询（ConcurrentRateLimiter.kt:40-51,86-92,97-105）。
- N/M=固定窗口（非滑窗）：窗口锚=首次放行时刻，满窗等待至窗口重置，N 个可同时在途；边界可突发 2N；记录 freq 初值 1 导致实际放行 N+1 次（:52-69,30）。
- EasyRead rate_limit_interceptor：Future 链串行强制并发 1（偏离 Legado 窗口模式，rate_limit_interceptor.dart:16-37）；窗口恰好 N 次（比 Legado N+1 严，:109）；默认 1s 间隔（:12，Legado 默认不限）；JS 网络绕过限流（js_network.dart:40-44）；建议 N/M 模式不串行、对齐 N+1、1s 默认保留为可配策略。
## Cookie
- Legado：按 eTLD+1 域键控（NetworkUtils.kt:168-179）；session（内存 LRU 重启失效）/持久（Room）分离（CookieManager.kt:41-50,81-94）；全响应捕获 Set-Cookie 并按名合并（HttpHelper.kt:84-100，CookieStore.kt:34-47）；>4096 字符随机删键（CookieStore.kt:61-66）；中毒自动清除（CookieManager.kt:68-72）；备份不含 cookie（Backup.kt:47-70 无 cookie.json）。
- EasyRead：按 sourceId 键控 AES 盒（cookie_jar_service.dart:14-30）；仅登录流捕获 Set-Cookie 且只留 name=value（search_repository_impl.dart:109-116,847-853）。
- 差距：普通搜索/详情/正文响应无 Set-Cookie 回写→会话轮换后登录态静默衰减（最大差距）；登录流整体替换而非按名合并；同域多书源不共享、cookie 广播到源内任意 host（过度发送）。
- EasyRead 独有机会：手工重定向环可逐跳抓 Set-Cookie（dio_client.dart:253-285，Legado 做不到）；JS 网络请求未注入存储 Cookie（js_network.dart:132-145）。
## HTTP 健壮性
- 超时：Legado connect15/write15/read60/call60 + 按源 readTimeout 覆盖（HttpHelper.kt:59-62，AnalyzeUrl.kt:452-459）；EasyRead connect10/receive15 且无按源覆盖（dio_client.dart:25-26）——慢速 CDN 易被切断。
- 重试：EasyRead 更优（3 次、退避、POST 副作用不重试，retry_interceptor.dart:18-59）；Legado 盲目重试非 2xx N 次无退避（OkHttpUtils.kt:27-41）。
- SSL：Legado 恒 trust-all+主机名绕过（HttpHelper.kt:64-66，SSLHelper.kt:27-49）兼容自签站点；EasyRead 系统校验——兼容性差距，至多按源 opt-in，不建议默认。
- 编码：Legado 规则→Content-Type→内容自动检测三级 + BOM 去除 + application/zip 自动解压（OkHttpUtils.kt:79-110）；EasyRead 仅规则 gbk 否则 utf8-allowMalformed（dio_client.dart:169-181）——不读响应 charset，易乱码。
## 存储
- Legado：单 Room 库 v74，手工迁移链 10→43 + AutoMigration 43→74，exportSchema，v<9 直接破坏性兜底（AppDatabase.kt:57-106，DatabaseMigrations.kt:13-24）——可借鉴「显式版本下限」声明。
- EasyRead Hive 自愈已强于 Legado：帧 CRC 预检、尾部截断修复、首帧损坏 .bak 备份开新盒、密钥永不覆盖（hive_init.dart:111-174,40-47）。
- Legado 无盒轮转/快照，损坏兜底=每日自动备份（Backup.kt:83-105）——机制价值：本地轮转快照限制损坏爆炸半径（产品已砍备份，仅评估）。
## 大文件
- Legado RuleBigDataHelp 非大 JSON 机制：是 JS 规则大变量的磁盘 KV（ruleData/<md5>/<md5>.txt，RuleBigDataHelp.kt:15-17,54-77）；书源导入也是全内存 GSON——不可对标。
- EasyRead 现状：50MB 上限 + 整串下载解码，>512K 字符数组下沉 isolate（import_book_source.dart:39,262-308），峰值内存≈3-4×文件大小。
- 建议（50MB+）：单遍字符串/转义状态机切顶层数组元素边界→isolate 内分批 jsonDecode 逐元素，峰值≈最大元素；边界：字符串内括号、\u0022 等转义须整段消费、BOM/空白、单对象非数组走旧路径、失败记录字节偏移供报错。
## 总体建议（按优先级）
- P0：按源 Set-Cookie 全局自动回写（按名合并、含重定向逐跳）——修复登录态衰减，最大单点。
- P0：JS 网络请求统一传 sourceId/concurrentRate 并注入存储 Cookie（对齐 Legado 统一客户端）。
- P1：限流 N/M 模式不串行（允许 N 在途）、对齐 N+1 语义、1s 默认间隔改为可配。
- P1：尊重 Content-Type charset + 去 BOM；章节缓存盒加字节预算（如 100MB）+ 清缓存入口（现有 LRU 500 条只限条数不限字节，reader_repository_impl.dart:679-692）。
- P2：50MB+ 源集元素切分器导入；按源超时覆盖；cookie 4096 上限 + 中毒自清。
- 不值得学：Cronet/HTTP3（Dart 侧无等价）、ObsoleteUrlFactory（JVM 专属）、WebDAV 增量（Legado 本身仅同日 latest-wins）、Room exportSchema 工具链、trust-all 默认化、EventMessage（Riverpod 已覆盖）。
