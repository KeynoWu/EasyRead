# M2 拆分方案（行为等价重构）

> 目标：三个核心巨型类按职责拆分，**不改任何规则语义**，原测试逐字保留且全绿。
> 每步门禁：`dart analyze` 0 + 对应测试全绿 → 提交。

## 1. reader_repository_impl.dart（~1310 行）

新建 `lib/features/reader/data/repositories/catalog_parser.dart` 与 `content_extractor.dart`（纯静态工具类），
`reader_repository_impl.dart` 保留编排+缓存+进度，改为调用工具类。

- **catalog_parser.dart**（目录域）：
  _parseCatalogPage、_parseBookInfo、_formatTocItem、_isVolumeItem、_extractNextUrl、_decodeJsListItems、
  _jsTruthy、_extractField、_extractFromPage、_resolveUrl、_ParsedBookInfo
- **content_extractor.dart**（正文域）：
  _extractContentPage、_extractMainText、_visibleText、_removeRepeatedTitle、resolveImageUrls、
  _applyContentReplaceRegex、_replaceAllSafe、_buildContentUrl、_extractNextUrl(正文分页共用)
- **reader_repository_impl.dart**（编排）：getCatalog/getBookDetail/getChapter/saveProgress/loadProgress/
  clearBookCache/preloadChapters/_trimCache/_chapterCacheKey/matchesBookUrlPattern/_EmptySourceRepo/ChapterLoadException

## 2. rule_engine.dart（1277 行）

拆为三个类（同目录）：
- **rule_parser.dart** → class RuleParser：_splitRule、_splitRuleForCascade、_parseCascade、_parseIndexSet、
  规则类型判定（_isCssRule/_isXPathRule/_isJsonPath/_isAllInOneRule/_isJsRule/_multiRuleType/_normalizeJsonPath）、
  _needsCaptureGroup、_findMatchingParen；私有类型 _RuleParts/_CascadeStep/_IndexRange/_XPathStep/_XPathSpec/
  _XPathCondition/_ReplaceSuffix
- **selector_engine.dart** → class SelectorEngine：_regexElements、_xpathTextList、_xpathElements、_xpathQueryAll、
  _xpathSteps、_xpathStepCss、_xpathDirectChildren、_xpathElementMatches、queryIn、valueOf、_queryAll、_queryCss、
  _cascadeQuery、_queryStep、_expandIndexes、_hasContainsPseudo、_queryWithContains、_matchesContains、_extractValue、
  _applyReplaceSuffix、_applyReplaceSuffixToValue、_expandReplacement、_jsonToString、_extractFromGroups、
  _jsonPathOf、_cssRuleOf、_xpathOf、_allInOneOf
- **rule_engine.dart** → Facade：extractText、extractTextList、extractElements、getElementText、isJsRule（委托前两者）

## 3. js_rule_executor.dart（2553 行）

拆为 5 个文件（同目录；方法多为 static 且互相引用，采用**独立静态类 + 类名限定调用**）：
- **js_bridge.dart**：java.* 桥与模板记录-重放 prelude、_readOps/_replayOps/_elementSnapshot/_parseUrls、
  _extractLiterals/_extractGetStringCache/_queryGetString/_extractGetStringListCache/_queryGetStringList、
  _prelude/_recordPrelude/_templateRecordPrelude/_templateRealPrelude/_readTemplateCaches/_readStringList/_readInt/
  _readPutMap/_mergePutMap/_mergeCookies
- **js_network.dart**：ajax 安全网络（fetcher、_fetchAll、_readNetworkOps、_fetchNetworkResults、_stringMap、
  _resolveUrl、_isSameSite、worker、_NetworkOp）
- **js_crypto.dart**：加解密工具（_uuid4、时间戳、hmac/aes/digest/symmetric、hex/base64、json/html path 查询、
  _TimeArg/_HmacArg/_AesArg/_DigestArg/_SymmetricArg/_SymmetricOp）
- **js_record_replay.dart**：记录-重放核心（_TemplateCaches、模板 prelude、_readTemplateCaches、_mergePutMap、
  _mergeCookies、_readOps、_replayOps）
- **js_rule_executor.dart**：编排（execute、evalItemScript、_isOriginalItemJson、_getManager/_initManager/_recycle）

## 验收

每个文件拆分后：`dart analyze` 0 issues + 对应 feature 测试全绿（js_rule_executor_test 系列 / rule_engine_test 系列 /
reader_repository_* 系列 / rule_wiring_test / data_test 等），最后全量 flutter test 全绿并提交推送。
---

## js_rule_executor 拆分细则（M2-C，2026-08 补充）

文件结构：`lib/features/search/data/engines/` 下，方法均为 JsRuleExecutor 类 static（互调裸名），
拆分后跨类调用加类前缀；私有类归属如下。

### js_crypto.dart → class JsCrypto（纯工具，无 quickjs 依赖）
- 方法：_uuid4/_readTimeArgs/_formatTimestamp/_pad/_hmacHex/_hmacBase64/_readHmacArgs/
  _aesDecodeToString/_aesEncodeToBase64/_readAesArgs/_digestHex/_readDigestArgs/
  _readSymmetricArgs/_readSymmetricOps/_symmetricDecryptToString/_symmetricDecryptToBytes/
  _symmetricEncryptToBytes/_bytesToHex/_hexEncode/_hexDecode/_base64DecodeToString/
  _base64DecodeToBytes/_queryJsonPath/_queryHtmlPath
- 私有类：_TimeArg/_HmacArg/_AesArg/_DigestArg/_SymmetricArg/_SymmetricOp
- imports：dart:convert、dart:math、dart:typed_data、crypto、encrypt as encrypt、pointycastle as pc、
  html/parser as parser、json_path.dart

### js_network.dart → class JsNetwork（ajax 安全网络）
- 方法：fetcher 静态字段、networkClient 静态字段、_fetchAll/_readNetworkOps/_stringMap/
  _fetchNetworkResults/_resolveUrl/_isSameSite；两个 worker 局部函数随方法保留
- 私有类：_NetworkOp
- imports：dart:async、dart:convert、dio_client.dart、html/dom as dom、html/parser as parser

### js_bridge.dart → class JsBridge（java.* 桥 + prelude 生成）
- 方法：_scriptBody/_unsupported/_extractLiterals/_extractGetStringCache/_queryGetString/
  _extractGetStringListCache/_queryGetStringList/_quote/_cookieBridge/_prelude/_recordPrelude/
  _templateRecordPrelude/_templateRealPrelude/_readTemplateCaches/_readStringList/_readInt/
  _readPutMap/_mergePutMap/_mergeCookies
- 私有类：_TemplateCaches（realBridge getter 引用 JsCrypto 静态方法）
- imports：dart:convert、dart:typed_data、crypto、html/parser as parser、chinese_conversion、json_path、
  rule_engine.dart、js_crypto.dart、js_network.dart

### js_record_replay.dart → class JsRecordReplay（记录-重放核心）
- 方法：_readOps/_replayOps/_elementSnapshot/_parseUrls/_mergePutMap/_mergeCookies
- 私有类：_ElementSnapshot 类型（若有）
- imports：dart:convert、html/dom as dom、rule_engine.dart

### js_rule_executor.dart（编排保留）
- 方法：execute/evalItemScript/_isOriginalItemJson/_getManager/_initManager/_recycle/evalTemplate
- 常量：evalTimeout/ajaxTimeout/_finalPrelude/_ajaxRealBridge（prelude 常量可留或归 bridge）
- 顶层引擎状态（_manager/_failed/_pending/_lastFailedAt 等）保留在本文件
- 调用点：JsRuleExecutor.execute/evalItemScript/evalTemplate 被其它文件引用，签名与可见性不变
---

## ✅ 完成记录（2026-08-20）

| 阶段 | Commit | 拆分 |
|---|---|---|
| M2-A | 978b730 | reader_repository_impl(~1310) → catalog_parser(443)/content_extractor(230)/编排(705) |
| M2-B | f81dd8c | rule_engine(1277) → rule_parser/selector_engine/facade(3 文件) |
| M2-C1 | 16e173b | js_crypto（31 方法 + 6 类型） |
| M2-C2 | ab1a620 | js_network（ajax 安全网络 + NetworkOp） |
| M2-C3 | 8826c0b | js_record_replay（记录-重放 + TemplateCaches） |
| M2-C4 | da83daa | js_bridge（桥/prelude/JsCryptoCaches）→ js_rule_executor 537 行 |

全部：**dart analyze 0 issues + flutter test 356/356 全绿（原测试一字未改）+ 已推送 origin/main**。
