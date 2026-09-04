# 书源模型/管理/净化对照研究（EasyRead vs Legado 3.x）
## 1. BookSource 字段缺口（字段 | 语义:行号 | 频率 | 优先级）
1. lastUpdateTime | 导入冲突判定(新者胜)+更新时间排序:ImportBookSourceViewModel.kt:207-218 | 高频 | P0
2. loginUi | 登录表单JSON(RowUi text/password/button):SourceLoginDialog.kt:56-104 | 中频 | P2
3. customOrder | 手动排序/拖拽序号:BookSourceViewModel.kt:29-49 | 中频 | P3
4. bookSourceComment | 源说明+校验错误栈持久化:BookSource.kt:202-206 | 中频 | P3
5. variableComment | 自定义变量说明:BaseSource.kt:73 | 中频 | P3
6. ruleToc.preUpdateJs | 目录更新前反爬预处理JS:WebBook.kt:210-226 | 中频 | P2
7. ruleToc.isVip/isPay | 章节付费/VIP标记:BookChapter.kt:142-143 | 中频 | P3
8. ruleContent.webJs/sourceRegex | 正文请求预处理/源URL提取:ContentRule.kt:16-17 | 低频 | P3
9. ruleSearch.updateTime | 搜索结果更新时间:SearchRule.kt:21 | 低频 | P3
10. bookSourceType/coverDecodeJs/exploreScreen/ruleReview/canReName/downloadUrls/imageDecode | 文件源型/封面解密/发现筛选/段评/改名/下载/图片解密:BookSource.kt:41,69,83,97;BookInfoRule.kt:23-24 | 长尾 | P4-P5
## 2. RuleComplete 机制
1. 本质是"规则编写简化":autoComplete 给简单选择器尾部自动补 @text/@href/@src:RuleComplete.kt:7-85;并非"字段空时填预设值",全库 grep preferSource 零命中,该机制不存在。
2. master 快照无调用点、反编译 release 无此类(RuleComplete.kt:32)→Legado 自身休眠代码;EasyRead 用户是读者非源作者,既有 _nestedAliases 双向别名(book_source.dart:129-157)已解决兼容,不值得做。
## 3. 检测机制差距
1. 深度:Legado 全链路 搜索→详情→目录(前2章)→正文(首章):CheckSourceService.kt:154-242,五项开关:CheckSource.kt:18-22;EasyRead 只测搜索层:test_book_source.dart:30-71,"搜索通但目录/正文坏"会误判可用。
2. 参数与分类:Legado 超时默认180s可配:CheckSource.kt:17、源级checkKeyWord优先:BookSource.kt:208-215、失败写互斥group标签:CheckSourceService.kt:141-148;EasyRead 固定8s/固定"小说"+字符串匹配分类脆弱:batch_test_book_sources.dart:57-63,112-124。
3. 运行与持久化:Legado 前台Service+通知进程被杀不死:CheckSourceService.kt:53-132;EasyRead 页内worker池离开页面即取消:book_source_test_page.dart:40-41,百源数分钟流程易中断。
## 4. 订阅机制现状+最小方案
1. Legado 当前 release 无独立订阅 tab;导入支持 $.sourceUrls 容器/绝对URL(+unCompress/#requestWithoutUA)/逗号多URL:ImportBookSourceViewModel.kt:134-205;反编译BookSourceActivity.java:386,冲突=lastUpdateTime新者胜+keepName/keepGroup/keepEnable:ImportBookSourceViewModel.kt:85-128,207-218。
2. EasyRead 无订阅:无地址持久化/无更新入口(仅 import_page.dart:42 文案+2处注释残留 parse_book_source_rule.dart:8、retry_interceptor.dart:21);重导同源直接覆盖本地:import_book_source.dart:71-73,不解析 $.sourceUrls。
3. 最小方案:订阅盒(url+lastCheckedAt)+列表页"更新订阅"(默认跳过已有、保留本地enabled/group/规则只导新源)+_parseContent先试sourceUrls递归拉取(约10行);不做Legado三态选择对话框。
## 5. 登录机制差距
1. loginUrl 语义:Legado 是"登录脚本"(须定义 function login()):BaseSource.kt:73-99 + loginUi 账号表单:SourceLoginDialog.kt:155-176;EasyRead 视为真实URL抓Set-Cookie:search_repository_impl.dart:75-122,账号密码登录类源不支持。
2. 失效检测:Legado loginCheckJs 每请求执行失效即抛错→明确"未登录"错误:WebBook.kt:70-74等5处;EasyRead 宽松执行只更新cookie/重写html:search_repository_impl.dart:860-917,失败为通用报错用户不知已掉登录。
3. 存储与入口:Legado CookieStore按二级域名+loginHeader每请求合并:BaseSource.kt:104-159;CookieStore.kt:23-83 +"需要登录"筛选+登出;EasyRead 按sourceId单cookie串:cookie_jar_service.dart:5-31,无登出入口/无登录态展示。
## 6. 净化引擎差距
1. $N替换语义:Legado Java appendReplacement 解释$1/$&:RegexExtensions.kt:43;EasyRead JS路径展开:js_purifier.dart:153-170 但Dart路径字面替换:regex_purifier.dart:169-173,"Dart可编译+replacement含$N"规则与Legado行为不一致。
2. 标题应用点:Legado 目录列表+正文顶标题均净化:BookChapterList.kt:153-164;ContentProcessor.kt:180-186;EasyRead 仅正文加载时净化标题:reader_repository_impl.dart:496-501,目录标题未净化。
3. 简繁转换顺序:Legado 先转换后净化:ContentProcessor.kt:135-145;EasyRead 先净化后显示期转换:reader_provider.dart:398-399,繁体站点+简体规则会漏匹配。
4. 缺生效规则追踪:Legado effectiveReplaceRules 记录实际命中规则:ContentProcessor.kt:102,203;EasyRead 无(体验差距,实现成本低)。
5. 已对标无差距:13字段全集/scope双向contains生效:regex_purifier.dart:133-160 /3000ms超时+自动禁用持久化:manage_purification_rules.dart:232-235;purify_pipeline_provider.dart:25-30 /@js:result语义:js_purifier.dart:231-238。
## 7. 合规风险
1. rules.json 20条来自社区"阅读净化规则合集"(JSON数据非代码);Legado 官方 defaultData 无净化规则(assets/defaultData/+DefaultData.kt:45-111核实),不触碰"不复制正则"红线;主要风险是溯源,建议文件头/docs记录原始分发地址与许可,保留重写或授权通道。
## 8. 总体建议（P0/P1/P2）
P0:
1. lastUpdateTime字段+导入冲突处理(新者胜+保留本地enabled/group/规则)——当前重导静默覆盖本地:import_book_source.dart:71-73。
2. $N替换语义统一:Dart路径与JS路径一样展开捕获组,对齐Legado:regex_purifier.dart:169-173。
P1:
3. 检测深化:批量页加"详情+目录+正文"深度检测;尊重源级checkKeyWord;超时可配置(默认30s弃8s固定)。
4. 订阅最小方案:地址持久化+一键更新+$.sourceUrls容器(跳过已有、保留本地)。
P2:
5. 登录补口:登出入口+loginCheckJs异常时专用"登录已失效"文案;loginUi表单/登录JS按源需求再评估。
6. 目录标题净化+bookUrlPattern生效(换源匹配,reader_repository_impl.dart:148当前no-op)。
7. 简繁转换移至净化前,或在文档明示顺序差异。
8. 长尾字段(customOrder/preUpdateJs/isVip/isPay/comment等)按需补;ruleReview/音频图片源/TXT相关不做。
