import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/network/dio_client.dart';
import 'package:easy_read/features/book_source/domain/entities/book_source.dart';
import 'package:easy_read/features/book_source/domain/repositories/book_source_repository.dart';
import 'package:easy_read/features/book_source/domain/usecases/import_book_source.dart';
import 'package:easy_read/features/book_source/domain/usecases/parse_book_source_rule.dart';

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
class _SlowDownloadClient implements DioClient {
  final int totalChunks;

  _SlowDownloadClient({this.totalChunks = 20});

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId}) async {
    return '';
  }

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
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

/// 模拟 DioClient：下载中途停顿（超过空闲超时）
class _StalledClient implements DioClient {
  final Duration stall;

  _StalledClient(this.stall);

  @override
  Dio get dio => Dio();

  @override
  Future<String> getString(String url, {Map<String, String>? headers, String? sourceId}) async {
    return '';
  }

  @override
  Future<String> getStringWithProgress(
    String url, {
    Map<String, String>? headers,
    String? sourceId,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    onProgress?.call(100, 1000);
    await Future<void>.delayed(stall);
    onProgress?.call(200, 1000);
    return '[]';
  }
}

void main() {
  group('ImportBookSource.fromUrl', () {
    test('should download slow but steadily streaming source without timeout', () async {
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
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
    });

    test('should fail when download stalls beyond idle timeout', () async {
      final useCase = ImportBookSource(
        repository: _MockSourceRepo(),
        parser: ParseBookSourceRule(),
        client: _StalledClient(const Duration(milliseconds: 300)),
        idleTimeout: const Duration(milliseconds: 100),
        totalLimit: const Duration(seconds: 10),
      );
      final result = await useCase.fromUrl('https://example.com/sources.json');
      expect(result.isLeft, isTrue);
      result.fold((l) => expect(l, contains('网络请求失败')), (r) => fail('不应成功'));
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
  });
}
