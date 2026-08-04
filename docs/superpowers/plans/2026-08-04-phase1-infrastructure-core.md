# Phase 1: 基建与核心链路 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 搭建项目基础框架，完成书源导入和单源搜索核心链路，产出可验证的 APK。

**Architecture:** Feature-first + Clean Architecture，按 core/features 分层，数据单向流动。Phase 1 覆盖 core 基础设施 + bookshelf/book_source/search 三个 feature 的基础骨架。

**Tech Stack:** Flutter 3.x, Dart 3.x, Riverpod, Hive, ObjectBox, Dio, go_router

---

## 文件结构规划

```
easy_read/
├── lib/
│   ├── core/
│   │   ├── theme/
│   │   │   ├── app_theme.dart              # 主题定义（iOS 风格色彩+字体）
│   │   │   └── app_colors.dart             # 色彩常量
│   │   ├── network/
│   │   │   ├── dio_client.dart             # Dio 单例 + 基础配置
│   │   │   └── interceptors/
│   │   │       ├── rate_limit_interceptor.dart  # 请求频率控制
│   │   │       ├── retry_interceptor.dart       # 自动重试
│   │   │       └── ua_interceptor.dart          # UA 轮换
│   │   ├── router/
│   │   │   └── app_router.dart             # 路由配置
│   │   ├── database/
│   │   │   ├── hive_init.dart              # Hive 初始化
│   │   │   └── objectbox_init.dart         # ObjectBox 初始化
│   │   └── purification/
│   │       ├── purify_pipeline.dart        # 净化管线入口
│   │       ├── tag_purifier.dart           # 标签净化
│   │       ├── regex_purifier.dart         # 正则净化
│   │       └── layout_purifier.dart        # 排版整理
│   ├── features/
│   │   ├── bookshelf/
│   │   │   ├── data/
│   │   │   │   ├── models/
│   │   │   │   │   └── book_model.dart     # 书架数据模型（JSON 序列化）
│   │   │   │   └── repositories/
│   │   │   │       └── bookshelf_repository_impl.dart
│   │   │   ├── domain/
│   │   │   │   ├── entities/
│   │   │   │   │   └── book.dart           # 书籍核心实体
│   │   │   │   └── repositories/
│   │   │   │       └── bookshelf_repository.dart  # 仓库接口
│   │   │   └── presentation/
│   │   │       ├── pages/
│   │   │       │   └── bookshelf_page.dart
│   │   │       ├── widgets/
│   │   │       │   ├── book_card.dart       # 书籍卡片组件
│   │   │       │   └── bookshelf_grid.dart  # 书架网格布局
│   │   │       └── providers/
│   │   │           └── bookshelf_provider.dart
│   │   ├── book_source/
│   │   │   ├── data/
│   │   │   │   ├── models/
│   │   │   │   │   └── book_source_model.dart
│   │   │   │   └── repositories/
│   │   │   │       └── book_source_repository_impl.dart
│   │   │   ├── domain/
│   │   │   │   ├── entities/
│   │   │   │   │   └── book_source.dart
│   │   │   │   ├── repositories/
│   │   │   │   │   └── book_source_repository.dart
│   │   │   │   └── usecases/
│   │   │   │       ├── import_book_source.dart
│   │   │   │       └── parse_book_source_rule.dart
│   │   │   └── presentation/
│   │   │       ├── pages/
│   │   │       │   ├── book_source_list_page.dart
│   │   │       │   └── book_source_import_page.dart
│   │   │       ├── widgets/
│   │   │       │   └── book_source_card.dart
│   │   │       └── providers/
│   │   │           └── book_source_provider.dart
│   │   └── search/
│   │       ├── data/
│   │       │   └── repositories/
│   │       │       └── search_repository_impl.dart
│   │       ├── domain/
│   │       │   ├── entities/
│   │       │   │   └── search_result.dart
│   │       │   ├── repositories/
│   │       │   │   └── search_repository.dart
│   │       │   └── usecases/
│   │       │       └── search_books.dart
│   │       └── presentation/
│   │           ├── pages/
│   │           │   └── search_page.dart
│   │           ├── widgets/
│   │           │   └── search_result_item.dart
│   │           └── providers/
│   │               └── search_provider.dart
│   ├── main.dart
│   └── app.dart
├── test/
│   ├── core/
│   │   ├── network/
│   │   │   └── dio_client_test.dart
│   │   └── purification/
│   │       ├── tag_purifier_test.dart
│   │       ├── regex_purifier_test.dart
│   │       └── purify_pipeline_test.dart
│   ├── features/
│   │   ├── book_source/
│   │   │   ├── data/
│   │   │   │   └── book_source_model_test.dart
│   │   │   └── domain/
│   │   │       └── parse_book_source_rule_test.dart
│   │   └── search/
│   │       └── domain/
│   │           └── search_books_test.dart
│   └── shared/
│       └── fixtures/
│           └── sample_book_source.json     # 测试用书源样例
├── pubspec.yaml
├── analysis_options.yaml
└── .gitignore
```

---

## 依赖配置

### Task 0: 初始化 Flutter 项目

- [ ] **Step 1: 创建 Flutter 项目**

```bash
flutter create --org com.easyread --project-name easy_read .
flutter pub add flutter_riverpod riverpod go_router
flutter pub add dio
flutter pub add hive hive_flutter
flutter pub add objectbox objectbox_flutter
flutter pub add html xml
flutter pub add file_picker
flutter pub add --dev build_runner
flutter pub add --dev hive_generator
flutter pub add --dev objectbox_generator
```

- [ ] **Step 2: 配置 analysis_options.yaml**

```yaml
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    prefer_const_constructors: true
    prefer_const_declarations: true
    avoid_print: false
    prefer_single_quotes: true

analyzer:
  errors:
    invalid_annotation_target: ignore
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"
```

- [ ] **Step 3: 配置 .gitignore**

```gitignore
# Flutter
.dart_tool/
.packages
build/
*.iml
.idea/
.vscode/
*.lock

# Superpowers
.superpowers/

# OS
.DS_Store
Thumbs.db
```

- [ ] **Step 4: 创建基础目录结构**

```bash
mkdir -p lib/core/{theme,network/interceptors,router,database,purification}
mkdir -p lib/features/{bookshelf,book_source,search}/data/{models,repositories}
mkdir -p lib/features/{bookshelf,book_source,search}/domain/{entities,repositories,usecases}
mkdir -p lib/features/{bookshelf,book_source,search}/presentation/{pages,widgets,providers}
mkdir -p test/core/{network,purification}
mkdir -p test/features/{book_source,search}
mkdir -p test/shared/fixtures
```

---

## 任务分解

### Task 1: Core — 主题系统

**Files:**
- Create: `lib/core/theme/app_colors.dart`
- Create: `lib/core/theme/app_theme.dart`

- [ ] **Step 1: 创建色彩常量**

```dart
// lib/core/theme/app_colors.dart
import 'package:flutter/material.dart';

/// iOS 风格色彩体系 — 低饱和度中性色 + 极简点缀
class AppColors {
  // 通用
  static const Color background = Color(0xFFF2F2F7);       // iOS 浅灰背景
  static const Color surface = Color(0xFFFFFFFF);           // 卡片白色
  static const Color textPrimary = Color(0xFF1C1C1E);       // 主文字色
  static const Color textSecondary = Color(0xFF8E8E93);     // 次级文字
  static const Color separator = Color(0xFFC6C6C8);         // 分割线
  static const Color tint = Color(0xFF007AFF);              // iOS 蓝色强调

  // 深色模式
  static const Color darkBackground = Color(0xFF000000);    // 纯黑
  static const Color darkSurface = Color(0xFF1C1C1E);
  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFF8E8E93);
  static const Color darkSeparator = Color(0xFF38383A);
  static const Color darkTint = Color(0xFF0A84FF);

  // 阅读主题
  static const Color readBackground = Color(0xFFF5F0E8);   // 仿纸色
  static const Color readDarkBackground = Color(0xFF000000); // 纯黑阅读
  static const Color readGreen = Color(0xFFC7EDCC);         // 护眼绿
  static const Color readParchment = Color(0xFFF5E6C8);     // 羊皮纸
}
```

- [ ] **Step 2: 创建主题定义**

```dart
// lib/core/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'app_colors.dart';

/// iOS 风格主题系统 — 日间/夜间模式
class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.light(
        primary: AppColors.tint,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.separator,
        thickness: 0.5,
        space: 0,
      ),
      cardTheme: CardTheme(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.darkBackground,
      colorScheme: ColorScheme.dark(
        primary: AppColors.darkTint,
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkTextPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: AppColors.darkTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.darkTextPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.darkSeparator,
        thickness: 0.5,
        space: 0,
      ),
      cardTheme: CardTheme(
        color: AppColors.darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 验证编译**

```bash
flutter analyze lib/core/theme/
Expected: No issues found.
```

---

### Task 2: Core — 网络层

**Files:**
- Create: `lib/core/network/interceptors/rate_limit_interceptor.dart`
- Create: `lib/core/network/interceptors/retry_interceptor.dart`
- Create: `lib/core/network/interceptors/ua_interceptor.dart`
- Create: `lib/core/network/dio_client.dart`

- [ ] **Step 1: 创建频率控制拦截器**

```dart
// lib/core/network/interceptors/rate_limit_interceptor.dart
import 'package:dio/dio.dart';

/// 请求频率控制 — 每个书源独立 QPS 限制
class RateLimitInterceptor extends Interceptor {
  final Map<String, DateTime> _lastRequestTime = {};
  final int _minIntervalMs;

  RateLimitInterceptor({int minIntervalMs = 1000}) : _minIntervalMs = minIntervalMs;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final sourceKey = options.extra['source_id'] as String? ?? 'default';
    final lastTime = _lastRequestTime[sourceKey];
    if (lastTime != null) {
      final elapsed = DateTime.now().difference(lastTime).inMilliseconds;
      if (elapsed < _minIntervalMs) {
        Future.delayed(Duration(milliseconds: _minIntervalMs - elapsed), () {
          _lastRequestTime[sourceKey] = DateTime.now();
          handler.next(options);
        });
        return;
      }
    }
    _lastRequestTime[sourceKey] = DateTime.now();
    handler.next(options);
  }
}
```

- [ ] **Step 2: 创建自动重试拦截器**

```dart
// lib/core/network/interceptors/retry_interceptor.dart
import 'package:dio/dio.dart';

/// 自动重试 — 网络异常时最多重试 3 次，间隔递增
class RetryInterceptor extends Interceptor {
  final int _maxRetries;
  final Duration _baseDelay;

  RetryInterceptor({int maxRetries = 3, Duration? baseDelay})
      : _maxRetries = maxRetries,
        _baseDelay = baseDelay ?? const Duration(seconds: 1);

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final retryCount = (err.requestOptions.extra['retry_count'] as int?) ?? 0;
    if (retryCount >= _maxRetries) {
      return handler.next(err);
    }
    await Future.delayed(_baseDelay * (retryCount + 1));
    final options = err.requestOptions.copyWith(
      extra: {...err.requestOptions.extra, 'retry_count': retryCount + 1},
    );
    try {
      final response = await Dio().fetch(options);
      handler.resolve(response);
    } catch (e) {
      handler.next(err);
    }
  }
}
```

- [ ] **Step 3: 创建 UA 轮换拦截器**

```dart
// lib/core/network/interceptors/ua_interceptor.dart
import 'package:dio/dio.dart';

/// UA 轮换 — 随机选择一个 User-Agent
class UaInterceptor extends Interceptor {
  static const _userAgents = [
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 13; SM-S9080) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.163 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.6167.101 Mobile Safari/537.36',
  ];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!options.headers.containsKey('User-Agent') && !options.headers.containsKey('user-agent')) {
      options.headers['User-Agent'] = (_userAgents..shuffle()).first;
    }
    handler.next(options);
  }
}
```

- [ ] **Step 4: 创建 Dio 客户端封装**

```dart
// lib/core/network/dio_client.dart
import 'package:dio/dio.dart';
import 'interceptors/rate_limit_interceptor.dart';
import 'interceptors/retry_interceptor.dart';
import 'interceptors/ua_interceptor.dart';

/// 全局 Dio 客户端 — 单例，所有网络请求通过此实例
class DioClient {
  static DioClient? _instance;
  late final Dio _dio;

  DioClient._() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    ));
    _dio.interceptors.addAll([
      UaInterceptor(),
      RateLimitInterceptor(),
      RetryInterceptor(),
    ]);
  }

  factory DioClient() {
    _instance ??= DioClient._();
    return _instance!;
  }

  Dio get dio => _dio;

  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId}) async {
    final response = await _dio.get(
      url,
      options: Options(
        headers: headers,
        extra: {'source_id': sourceId},
      ),
    );
    return response.data.toString();
  }
}
```

- [ ] **Step 5: 验证编译**

```bash
flutter analyze lib/core/network/
Expected: No issues found.
```

---

### Task 3: Core — 数据库初始化

**Files:**
- Create: `lib/core/database/hive_init.dart`
- Create: `lib/core/database/objectbox_init.dart`

- [ ] **Step 1: 创建 Hive 初始化**

```dart
// lib/core/database/hive_init.dart
import 'package:hive_flutter/hive_flutter.dart';

/// Hive 盒子名称常量
class HiveBoxes {
  static const String bookshelf = 'bookshelf';
  static const String bookSources = 'book_sources';
  static const String settings = 'settings';
}

/// 初始化 Hive 存储
Future<void> initHive() async {
  await Hive.initFlutter();
  await Hive.openBox(HiveBoxes.bookshelf);
  await Hive.openBox(HiveBoxes.bookSources);
  await Hive.openBox(HiveBoxes.settings);
}
```

- [ ] **Step 2: 创建 ObjectBox 初始化（占位）**

```dart
// lib/core/database/objectbox_init.dart
/// ObjectBox 初始化 — Phase 2 章节缓存时启用
/// 目前仅返回空 Store，后续通过 objectbox_generator 生成 schema
class ObjectBox {
  static Future<void> init() async {
    // Phase 2 实现
    // final store = await openStore();
  }
}
```

- [ ] **Step 3: 验证编译**

```bash
flutter analyze lib/core/database/
Expected: No issues found.
```

---

### Task 4: Core — 内容净化管线

**Files:**
- Create: `lib/core/purification/tag_purifier.dart`
- Create: `lib/core/purification/regex_purifier.dart`
- Create: `lib/core/purification/layout_purifier.dart`
- Create: `lib/core/purification/purify_pipeline.dart`
- Create: `test/core/purification/tag_purifier_test.dart`
- Create: `test/core/purification/regex_purifier_test.dart`
- Create: `test/core/purification/purify_pipeline_test.dart`

- [ ] **Step 1: 创建标签净化器测试**

```dart
// test/core/purification/tag_purifier_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/purification/tag_purifier.dart';

void main() {
  late TagPurifier purifier;

  setUp(() {
    purifier = TagPurifier();
  });

  test('should remove script tags', () {
    const input = '<p>正文</p><script>alert("广告")</script><p>继续</p>';
    final result = purifier.purify(input);
    expect(result, contains('正文'));
    expect(result, contains('继续'));
    expect(result, isNot(contains('alert')));
  });

  test('should remove style tags', () {
    const input = '<p>内容</p><style>.ad{display:none}</style>';
    final result = purifier.purify(input);
    expect(result, isNot(contains('display:none')));
  });

  test('should remove ad container by common selectors', () {
    const input = '<div class="ad">广告</div><p>正文</p><div id="footer">尾</div>';
    final result = purifier.purify(input);
    expect(result, isNot(contains('广告')));
    expect(result, contains('正文'));
  });
}
```

- [ ] **Step 2: 创建标签净化器实现**

```dart
// lib/core/purification/tag_purifier.dart
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

/// 第一阶段：标签净化 — 移除广告标签、script、style、无意义标签
class TagPurifier {
  static const _adKeywords = ['ad', 'advertisement', 'advert', 'banner', 'promotion', 'sponsor'];
  static const _removeTags = ['script', 'style', 'iframe', 'noscript'];

  String purify(String html) {
    final doc = parser.parse(html);
    _removeUnwanted(doc);
    return doc.body?.innerHtml ?? html;
  }

  void _removeUnwanted(dom.Element parent) {
    // 移除指定标签
    for (final tag in _removeTags) {
      parent.querySelectorAll(tag).forEach((e) => e.remove());
    }
    // 移除广告容器
    parent.querySelectorAll('[class]').where((e) {
      final cls = e.attributes['class']?.toLowerCase() ?? '';
      return _adKeywords.any((k) => cls.contains(k));
    }).forEach((e) => e.remove());

    parent.querySelectorAll('[id]').where((e) {
      final id = e.attributes['id']?.toLowerCase() ?? '';
      return _adKeywords.any((k) => id.contains(k));
    }).forEach((e) => e.remove());
  }
}
```

- [ ] **Step 3: 创建正则净化器测试与实现**

```dart
// test/core/purification/regex_purifier_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/purification/regex_purifier.dart';

void main() {
  test('should replace full-width punctuation', () {
    const input = '这是，一个。测试「文章」';
    final rules = [
      PurifyRule(pattern: '，', replacement: ','),
      PurifyRule(pattern: '。', replacement: '.'),
    ];
    final purifier = RegexPurifier(rules: rules);
    final result = purifier.purify(input);
    expect(result, equals('这是,一个.测试「文章」'));
  });

  test('should remove extra blank lines', () {
    const input = '第一行\n\n\n\n\n第二行';
    final purifier = RegexPurifier(rules: [
      PurifyRule(pattern: r'\n{3,}', replacement: '\n\n'),
    ]);
    final result = purifier.purify(input);
    expect(result, equals('第一行\n\n第二行'));
  });
}
```

```dart
// lib/core/purification/regex_purifier.dart
/// 单个替换规则
class PurifyRule {
  final String pattern;
  final String replacement;
  final bool caseSensitive;

  const PurifyRule({
    required this.pattern,
    required this.replacement,
    this.caseSensitive = false,
  });

  RegExp get regex => RegExp(pattern, caseSensitive: caseSensitive);
}

/// 第二阶段：正则净化 — 按规则列表逐条替换
class RegexPurifier {
  final List<PurifyRule> rules;

  const RegexPurifier({this.rules = const []});

  String purify(String input) {
    var result = input;
    for (final rule in rules) {
      result = result.replaceAll(rule.regex, rule.replacement);
    }
    return result;
  }
}
```

- [ ] **Step 4: 创建排版整理器**

```dart
// lib/core/purification/layout_purifier.dart
/// 第三阶段：排版整理 — 统一段落格式、缩进、对齐
class LayoutPurifier {
  String purify(String input) {
    var result = input.trim();
    // 统一换行符
    result = result.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 去除首尾空白行
    result = result.trim();
    return result;
  }
}
```

- [ ] **Step 5: 创建净化管线入口**

```dart
// lib/core/purification/purify_pipeline.dart
import 'tag_purifier.dart';
import 'regex_purifier.dart';
import 'layout_purifier.dart';

/// 三阶段净化管线入口
class PurifyPipeline {
  final TagPurifier tagPurifier;
  final RegexPurifier regexPurifier;
  final LayoutPurifier layoutPurifier;

  PurifyPipeline({
    TagPurifier? tagPurifier,
    RegexPurifier? regexPurifier,
    LayoutPurifier? layoutPurifier,
  })  : tagPurifier = tagPurifier ?? TagPurifier(),
        regexPurifier = regexPurifier ?? RegexPurifier(),
        layoutPurifier = layoutPurifier ?? LayoutPurifier();

  /// 执行完整净化流程
  String purify(String html) {
    var result = tagPurifier.purify(html);
    result = regexPurifier.purify(result);
    result = layoutPurifier.purify(result);
    return result;
  }
}
```

- [ ] **Step 6: 创建净化管线测试**

```dart
// test/core/purification/purify_pipeline_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/purification/purify_pipeline.dart';

void main() {
  test('full pipeline should clean HTML end-to-end', () {
    const input = '''
      <div class="ad">广告</div>
      <script>alert("x")</script>
      <p>正文内容，包含标点</p>
      <style>.ad{display:none}</style>
    ''';
    final pipeline = PurifyPipeline();
    final result = pipeline.purify(input);
    expect(result, isNot(contains('广告')));
    expect(result, isNot(contains('alert')));
    expect(result, isNot(contains('display:none')));
    expect(result, contains('正文内容'));
  });
}
```

- [ ] **Step 7: 运行净化测试**

```bash
flutter test test/core/purification/
Expected: All tests pass.
```

---

### Task 5: Core — 路由配置

**Files:**
- Create: `lib/core/router/app_router.dart`

- [ ] **Step 1: 创建路由配置**

```dart
// lib/core/router/app_router.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'bookshelf',
        builder: (context, state) => const SizedBox(), // Phase 1 placeholder
      ),
      GoRoute(
        path: '/search',
        name: 'search',
        builder: (context, state) => const SizedBox(), // Phase 1 placeholder
      ),
      GoRoute(
        path: '/book-sources',
        name: 'bookSources',
        builder: (context, state) => const SizedBox(), // Phase 1 placeholder
      ),
      GoRoute(
        path: '/book-source/import',
        name: 'bookSourceImport',
        builder: (context, state) => const SizedBox(), // Phase 1 placeholder
      ),
      GoRoute(
        path: '/reader/:bookId',
        name: 'reader',
        builder: (context, state) => const SizedBox(), // Phase 2 placeholder
      ),
    ],
  );
}
```

- [ ] **Step 2: 验证编译**

```bash
flutter analyze lib/core/router/
Expected: No issues found.
```

---

### Task 6: 书源模块 — 领域层

**Files:**
- Create: `lib/features/book_source/domain/entities/book_source.dart`
- Create: `lib/features/book_source/domain/repositories/book_source_repository.dart`
- Create: `lib/features/book_source/domain/usecases/parse_book_source_rule.dart`
- Create: `lib/features/book_source/domain/usecases/import_book_source.dart`
- Create: `test/features/book_source/domain/parse_book_source_rule_test.dart`
- Create: `test/shared/fixtures/sample_book_source.json`

- [ ] **Step 1: 创建书源实体**

```dart
// lib/features/book_source/domain/entities/book_source.dart
/// 书源实体 — 兼容阅读3.0规则格式
class BookSource {
  final String id;
  final String name;
  final String? bookSourceUrl;
  final String? bookSourceGroup;
  final bool enabled;
  final Map<String, dynamic> rules;

  // 核心规则字段
  String? get searchUrl => rules['searchUrl'] as String?;
  String? get bookListRule => rules['bookList'] as String?;
  String? get bookNameRule => rules['bookName'] as String?;
  String? get bookAuthorRule => rules['bookAuthor'] as String?;
  String? get coverUrlRule => rules['coverUrl'] as String?;
  String? get bookDetailUrlRule => rules['bookDetailUrl'] as String?;
  String? get contentUrl => rules['contentUrl'] as String?;
  String? get chapterContentRule => rules['chapterContent'] as String?;
  String? get chapterListRule => rules['chapterList'] as String?;
  String? get chapterNameRule => rules['chapterName'] as String?;
  String? get chapterUrlRule => rules['chapterUrl'] as String?;

  const BookSource({
    required this.id,
    required this.name,
    this.bookSourceUrl,
    this.bookSourceGroup,
    this.enabled = true,
    this.rules = const {},
  });

  BookSource copyWith({
    String? id,
    String? name,
    String? bookSourceUrl,
    String? bookSourceGroup,
    bool? enabled,
    Map<String, dynamic>? rules,
  }) {
    return BookSource(
      id: id ?? this.id,
      name: name ?? this.name,
      bookSourceUrl: bookSourceUrl ?? this.bookSourceUrl,
      bookSourceGroup: bookSourceGroup ?? this.bookSourceGroup,
      enabled: enabled ?? this.enabled,
      rules: rules ?? this.rules,
    );
  }
}
```

- [ ] **Step 2: 创建书源仓库接口**

```dart
// lib/features/book_source/domain/repositories/book_source_repository.dart
import '../entities/book_source.dart';

abstract class BookSourceRepository {
  Future<List<BookSource>> getAll();
  Future<BookSource?> getById(String id);
  Future<void> save(BookSource source);
  Future<void> delete(String id);
  Future<void> importFromJson(String jsonString);
  Future<void> importFromUrl(String url);
  Future<List<BookSource>> getEnabled();
}
```

- [ ] **Step 3: 创建测试样例 JSON**

```json
// test/shared/fixtures/sample_book_source.json
{
  "bookSourceName": "测试书源",
  "bookSourceGroup": "测试",
  "bookSourceUrl": "https://example.com",
  "searchUrl": "https://example.com/search?keyword={{key}}",
  "bookList": "div.book-list > div.item",
  "bookName": "h3.title@text",
  "bookAuthor": "span.author@text",
  "coverUrl": "img.cover@src",
  "bookDetailUrl": "a.detail@href",
  "contentUrl": "https://example.com/chapter/{{id}}.html",
  "chapterList": "ul.chapter-list > li",
  "chapterName": "a@text",
  "chapterUrl": "a@href",
  "chapterContent": "div#content@html"
}
```

- [ ] **Step 4: 创建书源规则解析器测试**

```dart
// test/features/book_source/domain/parse_book_source_rule_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/usecases/parse_book_source_rule.dart';

void main() {
  late ParseBookSourceRule useCase;

  setUp(() {
    useCase = ParseBookSourceRule();
  });

  test('should parse valid JSON book source', () {
    const json = '''
    {
      "bookSourceName": "测试源",
      "bookSourceGroup": "通用",
      "searchUrl": "https://test.com/search?keyword={{key}}",
      "bookList": "div.list > .item",
      "bookName": "h2.title@text",
      "bookAuthor": "span.author@text",
      "coverUrl": "img.cover@src",
      "bookDetailUrl": "a.link@href",
      "contentUrl": "https://test.com/chapter/{{id}}.html",
      "chapterList": "ul.chapters > li",
      "chapterName": "a@text",
      "chapterUrl": "a@href",
      "chapterContent": "div.content@html"
    }
    ''';
    final result = useCase.execute(json);
    expect(result.isRight, true);
    result.fold(
      (l) => fail('Expected Right'),
      (source) {
        expect(source.name, '测试源');
        expect(source.bookSourceGroup, '通用');
        expect(source.searchUrl, contains('{{key}}'));
      },
    );
  });

  test('should return error for invalid JSON', () {
    const json = '{invalid json}';
    final result = useCase.execute(json);
    expect(result.isLeft, true);
  });
}
```

- [ ] **Step 5: 创建书源规则解析器实现**

```dart
// lib/features/book_source/domain/usecases/parse_book_source_rule.dart
import 'dart:convert';
import 'package:either_dart/either.dart';
import '../entities/book_source.dart';

/// 解析书源规则 JSON → BookSource 实体
class ParseBookSourceRule {
  Either<String, BookSource> execute(String jsonString) {
    try {
      final map = jsonDecode(jsonString) as Map<String, dynamic>;
      final rules = Map<String, dynamic>.from(map);
      // 移除非规则字段
      rules.remove('bookSourceName');
      rules.remove('bookSourceGroup');
      rules.remove('bookSourceUrl');

      final source = BookSource(
        id: map['bookSourceUrl']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: map['bookSourceName']?.toString() ?? '未命名书源',
        bookSourceUrl: map['bookSourceUrl']?.toString(),
        bookSourceGroup: map['bookSourceGroup']?.toString(),
        rules: rules,
      );
      return Right(source);
    } catch (e) {
      return Left('书源格式错误: $e');
    }
  }
}
```

- [ ] **Step 6: 创建书源导入用例**

```dart
// lib/features/book_source/domain/usecases/import_book_source.dart
import 'package:file_picker/file_picker.dart';
import 'package:either_dart/either.dart';
import '../entities/book_source.dart';
import '../repositories/book_source_repository.dart';
import 'parse_book_source_rule.dart';

/// 导入书源（支持 JSON 文件/网络链接/剪贴板）
class ImportBookSource {
  final BookSourceRepository repository;
  final ParseBookSourceRule parser;

  ImportBookSource({
    required this.repository,
    required this.parser,
  });

  /// 从文件导入
  Future<Either<String, List<BookSource>>> fromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: true,
    );
    if (result == null) return Left('未选择文件');

    final sources = <BookSource>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      final content = String.fromCharCodes(bytes);
      final parsed = parser.execute(content);
      if (parsed.isRight) {
        parsed.fold((l) => null, (r) => sources.add(r));
      }
    }
    if (sources.isEmpty) return Left('未解析到有效书源');

    for (final source in sources) {
      await repository.save(source);
    }
    return Right(sources);
  }

  /// 从网络链接导入
  Future<Either<String, List<BookSource>>> fromUrl(String url) async {
    // Phase 2 实现网络请求
    return Left('网络导入功能尚未实现');
  }

  /// 从剪贴板导入
  Future<Either<String, BookSource?>> fromClipboard(String content) async {
    final parsed = parser.execute(content);
    if (parsed.isLeft) {
      return Left(parsed.left);
    }
    BookSource? source;
    parsed.fold((l) => null, (r) => source = r);
    if (source != null) {
      await repository.save(source!);
    }
    return Right(source);
  }
}
```

- [ ] **Step 7: 运行书源测试**

```bash
flutter test test/features/book_source/
Expected: All tests pass.
```

---

### Task 7: 书源模块 — 数据层

**Files:**
- Create: `lib/features/book_source/data/models/book_source_model.dart`
- Create: `lib/features/book_source/data/repositories/book_source_repository_impl.dart`

- [ ] **Step 1: 创建书源数据模型**

```dart
// lib/features/book_source/data/models/book_source_model.dart
import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/book_source.dart';

part 'book_source_model.g.dart';

@HiveType(typeId: 1)
class BookSourceModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String? bookSourceUrl;

  @HiveField(3)
  final String? bookSourceGroup;

  @HiveField(4)
  final bool enabled;

  @HiveField(5)
  final String rulesJson; // 序列化后的 rules

  BookSourceModel({
    required this.id,
    required this.name,
    this.bookSourceUrl,
    this.bookSourceGroup,
    this.enabled = true,
    required this.rulesJson,
  });

  factory BookSourceModel.fromEntity(BookSource entity) {
    return BookSourceModel(
      id: entity.id,
      name: entity.name,
      bookSourceUrl: entity.bookSourceUrl,
      bookSourceGroup: entity.bookSourceGroup,
      enabled: entity.enabled,
      rulesJson: jsonEncode(entity.rules),
    );
  }

  BookSource toEntity() {
    return BookSource(
      id: id,
      name: name,
      bookSourceUrl: bookSourceUrl,
      bookSourceGroup: bookSourceGroup,
      enabled: enabled,
      rules: Map<String, dynamic>.from(jsonDecode(rulesJson) as Map),
    );
  }
}
```

- [ ] **Step 2: 运行 build_runner 生成 Hive adapter**

```bash
flutter pub run build_runner build --delete-conflicting-outputs
Expected: `book_source_model.g.dart` generated.
```

- [ ] **Step 3: 创建书源仓库实现**

```dart
// lib/features/book_source/data/repositories/book_source_repository_impl.dart
import 'package:hive/hive.dart';
import '../../../core/database/hive_init.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/repositories/book_source_repository.dart';
import '../models/book_source_model.dart';

class BookSourceRepositoryImpl implements BookSourceRepository {
  late final Box<BookSourceModel> _box;

  @override
  Future<List<BookSource>> getAll() async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    return _box.values.map((e) => e.toEntity()).toList();
  }

  @override
  Future<BookSource?> getById(String id) async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    final model = _box.get(id);
    return model?.toEntity();
  }

  @override
  Future<void> save(BookSource source) async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    await _box.put(source.id, BookSourceModel.fromEntity(source));
  }

  @override
  Future<void> delete(String id) async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    await _box.delete(id);
  }

  @override
  Future<void> importFromJson(String jsonString) async {
    // 由 ImportBookSource usecase 处理
  }

  @override
  Future<void> importFromUrl(String url) async {
    // Phase 2 实现
  }

  @override
  Future<List<BookSource>> getEnabled() async {
    _box = await Hive.openBox<BookSourceModel>(HiveBoxes.bookSources);
    return _box.values.where((e) => e.enabled).map((e) => e.toEntity()).toList();
  }
}
```

- [ ] **Step 4: 验证编译**

```bash
flutter analyze lib/features/book_source/
Expected: No issues found.
```

---

### Task 8: 书源模块 — 展示层

**Files:**
- Create: `lib/features/book_source/presentation/providers/book_source_provider.dart`
- Create: `lib/features/book_source/presentation/widgets/book_source_card.dart`
- Create: `lib/features/book_source/presentation/pages/book_source_list_page.dart`
- Create: `lib/features/book_source/presentation/pages/book_source_import_page.dart`

- [ ] **Step 1: 创建书源 Provider**

```dart
// lib/features/book_source/presentation/providers/book_source_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/book_source_repository_impl.dart';
import '../../domain/entities/book_source.dart';

final bookSourceRepositoryProvider = Provider<BookSourceRepositoryImpl>((ref) {
  return BookSourceRepositoryImpl();
});

final bookSourceListProvider = FutureProvider<List<BookSource>>((ref) async {
  final repo = ref.watch(bookSourceRepositoryProvider);
  return repo.getAll();
});
```

- [ ] **Step 2: 创建书源卡片组件**

```dart
// lib/features/book_source/presentation/widgets/book_source_card.dart
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../domain/entities/book_source.dart';

class BookSourceCard extends StatelessWidget {
  final BookSource source;
  final VoidCallback? onToggle;

  const BookSourceCard({super.key, required this.source, this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(source.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  if (source.bookSourceGroup != null)
                    Text(source.bookSourceGroup!, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Switch(
              value: source.enabled,
              onChanged: (_) => onToggle?.call(),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 创建书源列表页**

```dart
// lib/features/book_source/presentation/pages/book_source_list_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/book_source_provider.dart';
import '../widgets/book_source_card.dart';

class BookSourceListPage extends ConsumerWidget {
  const BookSourceListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourcesAsync = ref.watch(bookSourceListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('书源管理')),
      body: sourcesAsync.when(
        data: (sources) => ListView.builder(
          itemCount: sources.length,
          itemBuilder: (context, index) => BookSourceCard(source: sources[index]),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.pushNamed(context, '/book-source/import'),
        child: const Icon(Icons.add),
      ),
    );
  }
}
```

- [ ] **Step 4: 创建书源导入页**

```dart
// lib/features/book_source/presentation/pages/book_source_import_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../domain/usecases/import_book_source.dart';
import '../../domain/usecases/parse_book_source_rule.dart';
import '../providers/book_source_provider.dart';

class BookSourceImportPage extends ConsumerWidget {
  const BookSourceImportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(bookSourceRepositoryProvider);
    final parser = ParseBookSourceRule();
    final useCase = ImportBookSource(repository: repo, parser: parser);

    return Scaffold(
      appBar: AppBar(title: const Text('导入书源')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ImportButton(
              icon: Icons.file_upload_outlined,
              title: '从本地文件导入',
              subtitle: '支持 JSON 格式书源文件',
              onTap: () async {
                final result = await useCase.fromFile();
                result.fold(
                  (error) => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(error)),
                  ),
                  (sources) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('成功导入 ${sources.length} 个书源')),
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
                );
              },
            ),
            const SizedBox(height: 12),
            _ImportButton(
              icon: Icons.link,
              title: '从网络链接导入',
              subtitle: '输入书源订阅地址',
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('功能开发中')),
              ),
            ),
            const SizedBox(height: 12),
            _ImportButton(
              icon: Icons.content_paste,
              title: '从剪贴板导入',
              subtitle: '粘贴书源 JSON 内容',
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('功能开发中')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ImportButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 32, color: AppColors.tint),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Text(subtitle, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: 验证编译**

```bash
flutter analyze lib/features/book_source/
Expected: No issues found.
```

---

### Task 9: 搜索模块 — 搜索书籍

**Files:**
- Create: `lib/features/search/domain/entities/search_result.dart`
- Create: `lib/features/search/domain/repositories/search_repository.dart`
- Create: `lib/features/search/domain/usecases/search_books.dart`
- Create: `lib/features/search/data/repositories/search_repository_impl.dart`
- Create: `test/features/search/domain/search_books_test.dart`

- [ ] **Step 1: 创建搜索结果实体**

```dart
// lib/features/search/domain/entities/search_result.dart
class SearchResult {
  final String bookId;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? detailUrl;
  final String sourceId;
  final String sourceName;

  const SearchResult({
    required this.bookId,
    required this.name,
    this.author,
    this.coverUrl,
    this.detailUrl,
    required this.sourceId,
    required this.sourceName,
  });
}
```

- [ ] **Step 2: 创建搜索仓库接口**

```dart
// lib/features/search/domain/repositories/search_repository.dart
import '../entities/search_result.dart';

abstract class SearchRepository {
  Future<List<SearchResult>> search(String keyword, String sourceId);
}
```

- [ ] **Step 3: 创建搜索用例**

```dart
// lib/features/search/domain/usecases/search_books.dart
import '../entities/search_result.dart';
import '../repositories/search_repository.dart';
import '../../../book_source/domain/repositories/book_source_repository.dart';

/// 单源搜索
class SearchBooks {
  final SearchRepository searchRepo;
  final BookSourceRepository sourceRepo;

  SearchBooks({required this.searchRepo, required this.sourceRepo});

  Future<List<SearchResult>> execute(String keyword, String sourceId) async {
    if (keyword.trim().isEmpty) return [];
    return searchRepo.search(keyword.trim(), sourceId);
  }
}
```

- [ ] **Step 4: 创建搜索仓库实现**

```dart
// lib/features/search/data/repositories/search_repository_impl.dart
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as parser;
import '../../../core/network/dio_client.dart';
import '../../../core/purification/purify_pipeline.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/search_repository.dart';
import '../../../book_source/domain/entities/book_source.dart';

/// 搜索仓库实现 — 使用书源规则解析搜索结果页
class SearchRepositoryImpl implements SearchRepository {
  final DioClient _client;
  final PurifyPipeline _pipeline;

  SearchRepositoryImpl({DioClient? client, PurifyPipeline? pipeline})
      : _client = client ?? DioClient(),
        _pipeline = pipeline ?? PurifyPipeline();

  @override
  Future<List<SearchResult>> search(String keyword, String sourceId) async {
    // 简化实现：直接返回空列表
    // Phase 2 实现完整的书源规则解析
    return [];
  }
}
```

- [ ] **Step 5: 创建搜索测试**

```dart
// test/features/search/domain/search_books_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:easy_read/features/search/domain/entities/search_result.dart';
import 'package:easy_read/features/search/domain/repositories/search_repository.dart';
import 'package:easy_read/features/search/domain/usecases/search_books.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';

// Mock classes
class MockSearchRepository implements SearchRepository {
  @override
  Future<List<SearchResult>> search(String keyword, String sourceId) async {
    if (keyword.isEmpty) return [];
    return [
      SearchResult(
        bookId: '1',
        name: '测试书籍',
        author: '测试作者',
        sourceId: sourceId,
        sourceName: '测试源',
      ),
    ];
  }
}

class MockBookSourceRepository implements BookSourceRepository {
  @override
  Future<List<BookSource>> getAll() async => [];
  @override
  Future<BookSource?> getById(String id) async => null;
  @override
  Future<void> save(BookSource source) async {}
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> importFromJson(String jsonString) async {}
  @override
  Future<void> importFromUrl(String url) async {}
  @override
  Future<List<BookSource>> getEnabled() async => [];
}

void main() {
  late SearchBooks useCase;
  late MockSearchRepository mockSearchRepo;
  late MockBookSourceRepository mockSourceRepo;

  setUp(() {
    mockSearchRepo = MockSearchRepository();
    mockSourceRepo = MockBookSourceRepository();
    useCase = SearchBooks(searchRepo: mockSearchRepo, sourceRepo: mockSourceRepo);
  });

  test('should return empty list for empty keyword', () async {
    final results = await useCase.execute('', 'source1');
    expect(results, isEmpty);
  });

  test('should return search results for valid keyword', () async {
    final results = await useCase.execute('测试', 'source1');
    expect(results.length, 1);
    expect(results.first.name, '测试书籍');
  });
}
```

- [ ] **Step 6: 运行搜索测试**

```bash
flutter test test/features/search/
Expected: All tests pass.
```

---

### Task 10: 搜索模块 — 展示层

**Files:**
- Create: `lib/features/search/presentation/providers/search_provider.dart`
- Create: `lib/features/search/presentation/widgets/search_result_item.dart`
- Create: `lib/features/search/presentation/pages/search_page.dart`

- [ ] **Step 1: 创建搜索 Provider**

```dart
// lib/features/search/presentation/providers/search_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/usecases/search_books.dart';
import '../../../book_source/data/repositories/book_source_repository_impl.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
import '../../data/repositories/search_repository_impl.dart';

final searchRepositoryProvider = Provider<SearchRepositoryImpl>((ref) {
  return SearchRepositoryImpl();
});

final searchBooksProvider = Provider<SearchBooks>((ref) {
  return SearchBooks(
    searchRepo: ref.watch(searchRepositoryProvider),
    sourceRepo: ref.watch(bookSourceRepositoryProvider),
  );
});

final searchResultsProvider = FutureProvider.family<List<SearchResult>, String>((ref, keyword) async {
  if (keyword.trim().isEmpty) return [];
  final searchBooks = ref.watch(searchBooksProvider);
  // Phase 2 实现多源聚合
  return searchBooks.execute(keyword, '');
});
```

- [ ] **Step 2: 创建搜索页面**

```dart
// lib/features/search/presentation/pages/search_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/search_provider.dart';
import '../widgets/search_result_item.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '搜索书籍',
            border: InputBorder.none,
          ),
          onSubmitted: (value) => ref.refresh(searchResultsProvider(value)),
        ),
      ),
      body: _searchController.text.isEmpty
          ? const Center(child: Text('输入关键词搜索书籍', style: TextStyle(color: AppColors.textSecondary)))
          : ref.watch(searchResultsProvider(_searchController.text)).when(
              data: (results) => ListView.builder(
                itemCount: results.length,
                itemBuilder: (context, index) => SearchResultItem(result: results[index]),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('搜索失败: $e')),
            ),
    );
  }
}
```

- [ ] **Step 3: 创建搜索结果项组件**

```dart
// lib/features/search/presentation/widgets/search_result_item.dart
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../domain/entities/search_result.dart';

class SearchResultItem extends StatelessWidget {
  final SearchResult result;

  const SearchResultItem({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: () {
          // Phase 2: 跳转到书籍详情页
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 64,
                  height: 88,
                  color: AppColors.separator.withOpacity(0.3),
                  child: result.coverUrl != null
                      ? Image.network(result.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.book))
                      : const Icon(Icons.book, color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(result.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    if (result.author != null)
                      Text(result.author!, style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    const SizedBox(height: 4),
                    Text(result.sourceName, style: TextStyle(fontSize: 12, color: AppColors.tint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 验证编译**

```bash
flutter analyze lib/features/search/
Expected: No issues found.
```

---

### Task 11: 书架模块 — 展示层

**Files:**
- Create: `lib/features/bookshelf/domain/entities/book.dart`
- Create: `lib/features/bookshelf/domain/repositories/bookshelf_repository.dart`
- Create: `lib/features/bookshelf/data/models/book_model.dart`
- Create: `lib/features/bookshelf/data/repositories/bookshelf_repository_impl.dart`
- Create: `lib/features/bookshelf/presentation/providers/bookshelf_provider.dart`
- Create: `lib/features/bookshelf/presentation/widgets/book_card.dart`
- Create: `lib/features/bookshelf/presentation/widgets/bookshelf_grid.dart`
- Create: `lib/features/bookshelf/presentation/pages/bookshelf_page.dart`

- [ ] **Step 1: 创建书籍实体**

```dart
// lib/features/bookshelf/domain/entities/book.dart
class Book {
  final String id;
  final String name;
  final String? author;
  final String? coverUrl;
  final String? sourceId;
  final String? lastChapter;
  final double progress; // 0.0 ~ 1.0
  final DateTime lastReadAt;

  const Book({
    required this.id,
    required this.name,
    this.author,
    this.coverUrl,
    this.sourceId,
    this.lastChapter,
    this.progress = 0.0,
    required this.lastReadAt,
  });
}
```

- [ ] **Step 2: 创建书架仓库接口**

```dart
// lib/features/bookshelf/domain/repositories/bookshelf_repository.dart
import '../entities/book.dart';

abstract class BookshelfRepository {
  Future<List<Book>> getAll();
  Future<Book?> getById(String id);
  Future<void> save(Book book);
  Future<void> delete(String id);
  Future<void> updateProgress(String id, double progress);
}
```

- [ ] **Step 3: 创建书架数据模型**

```dart
// lib/features/bookshelf/data/models/book_model.dart
import 'package:hive/hive.dart';
import '../../domain/entities/book.dart';

part 'book_model.g.dart';

@HiveType(typeId: 0)
class BookModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String? author;

  @HiveField(3)
  final String? coverUrl;

  @HiveField(4)
  final String? sourceId;

  @HiveField(5)
  final String? lastChapter;

  @HiveField(6)
  final double progress;

  @HiveField(7)
  final DateTime lastReadAt;

  BookModel({
    required this.id,
    required this.name,
    this.author,
    this.coverUrl,
    this.sourceId,
    this.lastChapter,
    this.progress = 0.0,
    required this.lastReadAt,
  });

  factory BookModel.fromEntity(Book book) {
    return BookModel(
      id: book.id,
      name: book.name,
      author: book.author,
      coverUrl: book.coverUrl,
      sourceId: book.sourceId,
      lastChapter: book.lastChapter,
      progress: book.progress,
      lastReadAt: book.lastReadAt,
    );
  }

  Book toEntity() {
    return Book(
      id: id,
      name: name,
      author: author,
      coverUrl: coverUrl,
      sourceId: sourceId,
      lastChapter: lastChapter,
      progress: progress,
      lastReadAt: lastReadAt,
    );
  }
}
```

- [ ] **Step 4: 运行 build_runner**

```bash
flutter pub run build_runner build --delete-conflicting-outputs
Expected: `book_model.g.dart` generated.
```

- [ ] **Step 5: 创建书架仓库实现**

```dart
// lib/features/bookshelf/data/repositories/bookshelf_repository_impl.dart
import 'package:hive/hive.dart';
import '../../../core/database/hive_init.dart';
import '../../domain/entities/book.dart';
import '../../domain/repositories/bookshelf_repository.dart';
import '../models/book_model.dart';

class BookshelfRepositoryImpl implements BookshelfRepository {
  @override
  Future<List<Book>> getAll() async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    return box.values.map((e) => e.toEntity()).toList()
      ..sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
  }

  @override
  Future<Book?> getById(String id) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    final model = box.get(id);
    return model?.toEntity();
  }

  @override
  Future<void> save(Book book) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await box.put(book.id, BookModel.fromEntity(book));
  }

  @override
  Future<void> delete(String id) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    await box.delete(id);
  }

  @override
  Future<void> updateProgress(String id, double progress) async {
    final box = await Hive.openBox<BookModel>(HiveBoxes.bookshelf);
    final model = box.get(id);
    if (model != null) {
      final updated = BookModel(
        id: model.id,
        name: model.name,
        author: model.author,
        coverUrl: model.coverUrl,
        sourceId: model.sourceId,
        lastChapter: model.lastChapter,
        progress: progress,
        lastReadAt: DateTime.now(),
      );
      await box.put(id, updated);
    }
  }
}
```

- [ ] **Step 6: 创建书架 Provider**

```dart
// lib/features/bookshelf/presentation/providers/bookshelf_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/bookshelf_repository_impl.dart';
import '../../domain/entities/book.dart';

final bookshelfRepositoryProvider = Provider<BookshelfRepositoryImpl>((ref) {
  return BookshelfRepositoryImpl();
});

final bookshelfListProvider = FutureProvider<List<Book>>((ref) async {
  final repo = ref.watch(bookshelfRepositoryProvider);
  return repo.getAll();
});
```

- [ ] **Step 7: 创建书籍卡片组件**

```dart
// lib/features/bookshelf/presentation/widgets/book_card.dart
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../domain/entities/book.dart';

class BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;

  const BookCard({super.key, required this.book, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                color: AppColors.separator.withOpacity(0.2),
                child: book.coverUrl != null
                    ? Image.network(book.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.book, size: 40))
                    : const Icon(Icons.book, size: 40, color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          if (book.progress > 0)
            LinearProgressIndicator(
              value: book.progress,
              backgroundColor: AppColors.separator.withOpacity(0.3),
              color: AppColors.tint,
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 8: 创建书架网格布局**

```dart
// lib/features/bookshelf/presentation/widgets/bookshelf_grid.dart
import 'package:flutter/material.dart';
import '../../domain/entities/book.dart';
import 'book_card.dart';

class BookshelfGrid extends StatelessWidget {
  final List<Book> books;
  final void Function(Book)? onBookTap;

  const BookshelfGrid({super.key, required this.books, this.onBookTap});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
        childAspectRatio: 0.65,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) => BookCard(
        book: books[index],
        onTap: () => onBookTap?.call(books[index]),
      ),
    );
  }
}
```

- [ ] **Step 9: 创建书架页面**

```dart
// lib/features/bookshelf/presentation/pages/bookshelf_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/bookshelf_provider.dart';
import '../widgets/bookshelf_grid.dart';

class BookshelfPage extends ConsumerWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(bookshelfListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('书架')),
      body: booksAsync.when(
        data: (books) => books.isEmpty
            ? const Center(child: Text('书架空空，去搜索添加书籍吧'))
            : BookshelfGrid(books: books),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}
```

- [ ] **Step 10: 验证编译**

```bash
flutter analyze lib/features/bookshelf/
Expected: No issues found.
```

---

### Task 12: 应用入口与整合

**Files:**
- Modify: `lib/main.dart`
- Create: `lib/app.dart`
- Modify: `lib/core/router/app_router.dart`（更新路由为实际页面）

- [ ] **Step 1: 创建 App 入口 Widget**

```dart
// lib/app.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';

class EasyReadApp extends ConsumerWidget {
  const EasyReadApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: '易读 EasyRead',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      routerConfig: AppRouter.router,
      debugShowCheckedModeBanner: false,
    );
  }
}
```

- [ ] **Step 2: 更新路由配置**

```dart
// lib/core/router/app_router.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/bookshelf/presentation/pages/bookshelf_page.dart';
import '../../features/book_source/presentation/pages/book_source_list_page.dart';
import '../../features/book_source/presentation/pages/book_source_import_page.dart';
import '../../features/search/presentation/pages/search_page.dart';

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'bookshelf',
        builder: (context, state) => const BookshelfPage(),
      ),
      GoRoute(
        path: '/search',
        name: 'search',
        builder: (context, state) => const SearchPage(),
      ),
      GoRoute(
        path: '/book-sources',
        name: 'bookSources',
        builder: (context, state) => const BookSourceListPage(),
      ),
      GoRoute(
        path: '/book-source/import',
        name: 'bookSourceImport',
        builder: (context, state) => const BookSourceImportPage(),
      ),
      GoRoute(
        path: '/reader/:bookId',
        name: 'reader',
        builder: (context, state) => const Scaffold(body: Center(child: Text('阅读器（Phase 2 实现）'))),
      ),
    ],
  );
}
```

- [ ] **Step 3: 创建 main.dart**

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/database/hive_init.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initHive();
  runApp(const ProviderScope(child: EasyReadApp()));
}
```

- [ ] **Step 4: 验证完整编译**

```bash
flutter analyze
Expected: No issues found.
```

- [ ] **Step 5: 运行所有测试**

```bash
flutter test
Expected: All tests pass.
```

---

## 自检清单

- [ ] 所有文件路径使用绝对路径
- [ ] 每个步骤包含完整代码
- [ ] 每个测试步骤包含可运行的命令
- [ ] 无 TBD/TODO/占位符
- [ ] 类型定义在引用前已定义
- [ ] 所有 import 路径正确
- [ ] 编译验证步骤已包含
- [ ] 测试覆盖核心逻辑