import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/data/services/source_subscription_store.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/book_source/domain/usecases/import_book_source.dart';
import 'package:easy_read/features/book_source/domain/usecases/parse_book_source_rule.dart';
import 'package:hive/hive.dart';

class _MockSourceRepo implements BookSourceRepository {
  final saved = <BookSource>[];

  @override
  Future<List<BookSource>> getAll() async => saved;
  @override
  Future<BookSource?> getById(String id) async => null;
  @override
  Future<void> save(BookSource source) async => saved.add(source);
  @override
  Future<void> delete(String id) async {}
  @override
  Future<void> importFromJson(String jsonString) async {}
  @override
  Future<void> importFromUrl(String url) async {}
  @override
  Future<List<BookSource>> getEnabled() async => saved;
}

/// 模拟 DioClient：慢速但持续传输的下载
/// P0-12：带已存在书源的仓储桩（getById 命中，save 按 id 覆盖）
class _SeededSourceRepo extends _MockSourceRepo {
  final Map<String, BookSource> existing;
  _SeededSourceRepo(this.existing);

  @override
  Future<BookSource?> getById(String id) async => existing[id];

  @override
  Future<void> save(BookSource source) async {
    saved.removeWhere((s) => s.id == source.id);
    saved.add(source);
  }
}

class _SlowDownloadClient implements DioClient {
  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> requestString(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    int retry = 0,
    CancelToken? cancelToken,
  }) async {
    if (method.toUpperCase() == 'POST' && body != null) {
      return postForm(
        url,
        headers: headers,
        body: body,
        sourceId: sourceId,
        concurrentRate: concurrentRate,
        charset: charset,
        cancelToken: cancelToken,
      );
    }
    return getString(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      charset: charset,
      cancelToken: cancelToken,
    );
  }

  final int totalChunks;

  _SlowDownloadClient({this.totalChunks = 20});

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId,
 String? concurrentRate, String? charset, CancelToken? cancelToken}) async {
    return '';
  }

  @override
  @override
  Future<(String, Map<String, List<String>>, int)> getResponse(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{}, 200);
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

  @override
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

  @override
  Future<(String, Map<String, List<String>>)> postFormFull(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{});
  }

  @override
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return '';
  }

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    for (var i = 1; i <= totalChunks; i++) {
      if (cancelToken?.isCancelled ?? false) {
        throw DioException(requestOptions: RequestOptions(path: url), type: DioExceptionType.cancel);
      }
      onProgress?.call(i * 100, totalChunks * 100);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return '[{"bookSourceName": "测试源", "bookSourceUrl": "https://example.com", "searchUrl": "https://example.com/s?q={{key}}"}]';
  }
}

/// 模拟 DioClient：连接成功但从不发送数据（首字节超时场景）
class _NeverSendsClient extends _StalledClient {
  _NeverSendsClient() : super(const Duration(seconds: 30));

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // 从不调用 onProgress；轮询取消状态以便测试及时断言
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (cancelToken?.isCancelled ?? false) {
        sawCancelled = true;
        break;
      }
    }
    return '[]';
  }
}

class _StalledClient implements DioClient {
  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> requestString(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    int retry = 0,
    CancelToken? cancelToken,
  }) async {
    if (method.toUpperCase() == 'POST' && body != null) {
      return postForm(
        url,
        headers: headers,
        body: body,
        sourceId: sourceId,
        concurrentRate: concurrentRate,
        charset: charset,
        cancelToken: cancelToken,
      );
    }
    return getString(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      charset: charset,
      cancelToken: cancelToken,
    );
  }

  final Duration stall;
  bool sawCancelled = false;

  _StalledClient(this.stall);

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId,
 String? concurrentRate, String? charset, CancelToken? cancelToken}) async {
    return '';
  }

  @override
  @override
  Future<(String, Map<String, List<String>>, int)> getResponse(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{}, 200);
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

      @override
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

@override
  @override
  Future<(String, Map<String, List<String>>)> postFormFull(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{});
  }

  @override
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return '';
  }

@override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    onProgress?.call(100, 1000);
    await Future<void>.delayed(stall);
    sawCancelled = cancelToken?.isCancelled ?? false;
    onProgress?.call(200, 1000);
    return '[]';
  }
}

class _TooLargeClient implements DioClient {
  @override
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    CancelToken? cancelToken,
  }) async => Uint8List(0);

  @override
  Future<String> requestString(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    int retry = 0,
    CancelToken? cancelToken,
  }) async {
    if (method.toUpperCase() == 'POST' && body != null) {
      return postForm(
        url,
        headers: headers,
        body: body,
        sourceId: sourceId,
        concurrentRate: concurrentRate,
        charset: charset,
        cancelToken: cancelToken,
      );
    }
    return getString(
      url,
      headers: headers,
      sourceId: sourceId,
      concurrentRate: concurrentRate,
      charset: charset,
      cancelToken: cancelToken,
    );
  }

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId,
 String? concurrentRate, String? charset, CancelToken? cancelToken}) async {
    return '';
  }

  @override
  @override
  Future<(String, Map<String, List<String>>, int)> getResponse(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{}, 200);
  }

  @override
  Future<Map<String, List<String>>> getResponseHeaders(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

      @override
  Future<Map<String, List<String>>> postFormHeaders(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    CancelToken? cancelToken,
  }) async {
    return {};
  }

@override
  @override
  Future<(String, Map<String, List<String>>)> postFormFull(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return ('', const <String, List<String>>{});
  }

  @override
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    CancelToken? cancelToken,
  }) async {
    return '';
  }

@override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,

    String? concurrentRate,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    onProgress?.call(ImportBookSource.maxSourceBytes + 1, -1);
    return '';
  }
}

void main() {
  group('ImportBookSource.fromUrl', () {
    test('should download slow but steadily streaming source without timeout', () async {
      final repo = _MockSourceRepo();
      final useCase = ImportBookSource(
        repository: repo,
        parser: ParseBookSourceRule(),
        client: _SlowDownloadClient(),
        idleTimeout: const Duration(seconds: 5),
      );
      final result = await useCase.fromUrl('https://example.com/sources.json');
      expect(result.isRight, isTrue);
      result.fold((l) => fail('不应失败: $l'), (sources) {
        expect(sources.length, 1);
        expect(sources.first.name, '测试源');
      });
      expect(repo.saved.length, 1, reason: '网络导入成功后应写入书源仓库');
    });

    test('should fail when download stalls beyond idle timeout', () async {
      final client = _StalledClient(const Duration(milliseconds: 300));
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: client,
        idleTimeout: const Duration(milliseconds: 100),
        totalLimit: const Duration(seconds: 10),
      );
      final result = await useCase.fromUrl('https://example.com/sources.json');
      expect(result.isLeft, isTrue);
      // 空闲超时现在以 ImportLimitExceeded 给出明确文案，不再伪装成网络请求失败
      result.fold((l) => expect(l, contains('下载中断')), (r) => fail('不应成功'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(client.sawCancelled, isTrue, reason: '空闲超时后应取消底层下载');
    });

    test('should fail when server never sends first byte', () async {
      final client = _NeverSendsClient();
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: client,
        firstByteTimeout: const Duration(milliseconds: 100),
        totalLimit: const Duration(seconds: 10),
      );
      final result = await useCase.fromUrl('https://example.com/sources.json');
      expect(result.isLeft, isTrue);
      result.fold((l) => expect(l, contains('未发送数据')), (r) => fail('不应成功'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.sawCancelled, isTrue, reason: '首字节超时后应取消底层下载');
    });

    test('should report cancellation', () async {
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: _SlowDownloadClient(totalChunks: 100),
        idleTimeout: const Duration(seconds: 5),
      );
      final token = CancelToken();
      final future = useCase.fromUrl('https://example.com/sources.json', cancelToken: token);
      token.cancel();
      final result = await future;
      expect(result.isLeft, isTrue);
      result.fold((l) => expect(l, contains('已取消')), (r) => fail('不应成功'));
    });

    test('should reject empty url', () async {
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: _SlowDownloadClient(),
      );
      final result = await useCase.fromUrl('   ');
      expect(result.isLeft, isTrue);
    });

    test('should reject oversized source file', () async {
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: _TooLargeClient(),
      );
      final result = await useCase.fromUrl('https://example.com/sources.json');
      expect(result.isLeft, isTrue);
      result.fold((l) => expect(l, contains('超过大小限制')), (r) => fail('不应成功'));
    });
  });

  group('ImportBookSource.fromClipboard', () {
    test('should save parsed clipboard sources', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {
            'text': '[{"bookSourceName":"剪贴板源","bookSourceUrl":"https://example.com"}]',
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final repo = _MockSourceRepo();
      final useCase = ImportBookSource(
        repository: repo,
        parser: ParseBookSourceRule(),
        client: _SlowDownloadClient(),
      );
      final result = await useCase.fromClipboard();
      expect(result.isRight, isTrue);
      expect(repo.saved.length, 1);
      expect(repo.saved.first.name, '剪贴板源');
    });

    test('P0-12 本地 lastUpdateTime 较新：导入跳过不覆盖', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {
            'text': '[{"bookSourceName":"旧导入","bookSourceUrl":"https://example.com","lastUpdateTime":1000}]',
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final repo = _SeededSourceRepo({
        'https://example.com': const BookSource(
          id: 'https://example.com',
          name: '本地版',
          bookSourceUrl: 'https://example.com',
          rules: {'lastUpdateTime': 2000},
        ),
      });
      final useCase = ImportBookSource(
        repository: repo,
        parser: ParseBookSourceRule(),
        client: _SlowDownloadClient(),
      );
      final result = await useCase.fromClipboard();
      expect(result.isRight, isTrue);
      expect(repo.saved, isEmpty, reason: '本地较新时导入应跳过');
    });

    test('P0-12 导入较新：覆盖规则但保留本地启用与分组', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return {
            'text': '[{"bookSourceName":"新导入","bookSourceUrl":"https://example.com","lastUpdateTime":3000,"bookSourceGroup":"新组"}]',
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final repo = _SeededSourceRepo({
        'https://example.com': const BookSource(
          id: 'https://example.com',
          name: '本地版',
          bookSourceUrl: 'https://example.com',
          enabled: false,
          bookSourceGroup: '本地组',
          rules: {'lastUpdateTime': 1000},
        ),
      });
      final useCase = ImportBookSource(
        repository: repo,
        parser: ParseBookSourceRule(),
        client: _SlowDownloadClient(),
      );
      final result = await useCase.fromClipboard();
      expect(result.isRight, isTrue);
      expect(repo.saved.length, 1);
      expect(repo.saved.first.name, '新导入');
      expect(repo.saved.first.enabled, isFalse, reason: '保留本地启用状态');
      expect(repo.saved.first.bookSourceGroup, '本地组', reason: '保留本地分组');
    });
  });

  group('§三-9 书源订阅', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('hive_sub');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      tempDir.deleteSync(recursive: true);
    });

    test('订阅容器 {"sourceUrls": [...]} 递归拉取，单地址失败不中断', () async {
      final client = _UrlMapClient(responses: {
        'https://ex.com/sub.json':
            '{"sourceUrls":["https://ex.com/a.json","https://ex.com/b.json","https://ex.com/broken.json"]}',
        'https://ex.com/a.json':
            '[{"bookSourceName":"源A","bookSourceUrl":"https://a.com"}]',
        'https://ex.com/b.json':
            '[{"bookSourceName":"源B","bookSourceUrl":"https://b.com"}]',
      }, failing: {
        'https://ex.com/broken.json',
      });
      final store = SourceSubscriptionStore();
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: client,
        subscriptionStore: store,
      );

      final result = await useCase.fromUrl('https://ex.com/sub.json');
      expect(result.isRight, isTrue);
      result.fold((l) => fail('不应失败: $l'), (sources) {
        expect(sources.map((s) => s.name), ['源A', '源B']);
      });
      // 容器自身与成功子地址都记录为订阅（子地址失败不记录）
      expect(client.requested, containsAll([
        'https://ex.com/a.json',
        'https://ex.com/b.json',
        'https://ex.com/broken.json',
      ]));
      final subs = await store.list();
      expect(subs.single.url, 'https://ex.com/sub.json');
      expect(subs.single.lastSourceCount, 2);
    });

    test('订阅子地址返回容器 → 不递归（深度 1，防容器链）', () async {
      final client = _UrlMapClient(responses: {
        'https://ex.com/outer.json':
            '{"sourceUrls":["https://ex.com/inner.json"]}',
        'https://ex.com/inner.json':
            '{"sourceUrls":["https://ex.com/a.json"]}',
        'https://ex.com/a.json':
            '[{"bookSourceName":"不应拉到","bookSourceUrl":"https://a.com"}]',
      });
      final store = SourceSubscriptionStore();
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: client,
        subscriptionStore: store,
      );

      final result = await useCase.fromUrl('https://ex.com/outer.json');
      expect(result.isLeft, isTrue,
          reason: '子容器不递归：inner.json 内容按普通 JSON 解析失败');
      // 只请求了 outer 与 inner，未沿容器链继续拉取 a.json
      expect(client.requested, ['https://ex.com/outer.json', 'https://ex.com/inner.json']);
    });

    test('订阅容器全失败 → 明确错误文案', () async {
      final client = _UrlMapClient(responses: {
        'https://ex.com/sub.json':
            '{"sourceUrls":["https://ex.com/broken.json"]}',
      }, failing: {
        'https://ex.com/broken.json',
      });
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: client,
        subscriptionStore: SourceSubscriptionStore(),
      );

      final result = await useCase.fromUrl('https://ex.com/sub.json');
      expect(result.isLeft, isTrue);
      result.fold((l) => expect(l, contains('拉取失败')), (r) => fail('不应成功'));
    });

    test('refreshSubscriptions 一键更新：成功记录合并数，失败给出错误', () async {
      final store = SourceSubscriptionStore();
      await store.recordChecked('https://ex.com/good.json');
      await store.recordChecked('https://ex.com/dead.json');

      final client = _UrlMapClient(responses: {
        'https://ex.com/good.json':
            '[{"bookSourceName":"更新源","bookSourceUrl":"https://up.com"}]',
      }, failing: {
        'https://ex.com/dead.json',
      });
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: client,
        subscriptionStore: store,
      );

      final results = await useCase.refreshSubscriptions();
      expect(results.length, 2);
      final good = results.firstWhere((r) => r.url == 'https://ex.com/good.json');
      final dead = results.firstWhere((r) => r.url == 'https://ex.com/dead.json');
      expect(good.isSuccess, isTrue);
      expect(good.updated, 1);
      expect(dead.isSuccess, isFalse);
      expect(dead.error, isNotNull);
    });

    test('无订阅时 refreshSubscriptions 返回空列表', () async {
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: _UrlMapClient(responses: {}),
        subscriptionStore: SourceSubscriptionStore(),
      );
      expect(await useCase.refreshSubscriptions(), isEmpty);
    });
  });
}

/// 按 URL 返回预设响应的客户端（订阅容器/刷新测试）；
/// [failing] 中的 URL 抛连接异常，模拟子地址失效。
class _UrlMapClient extends DioClient {
  final Map<String, String> responses;
  final Set<String> failing;
  final requested = <String>[];

  _UrlMapClient({required this.responses, this.failing = const {}})
      : super.forTesting(Dio());

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    String? concurrentRate,
    String? charset,
    Map<String, dynamic>? extra,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    requested.add(url);
    if (failing.contains(url)) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.connectionError,
      );
    }
    onProgress?.call(1, 1);
    return responses[url] ?? '';
  }
}
