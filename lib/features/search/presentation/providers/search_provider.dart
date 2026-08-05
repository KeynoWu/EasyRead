import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/usecases/search_books.dart';
import '../../../book_source/presentation/providers/book_source_provider.dart';
import '../../data/repositories/search_repository_impl.dart';

final searchRepositoryProvider = Provider<SearchRepositoryImpl>((ref) {
  return SearchRepositoryImpl();
});

final searchBooksProvider = Provider<SearchBooks>((ref) {
  final searchRepo = ref.watch(searchRepositoryProvider);
  final sourceRepo = ref.watch(bookSourceRepositoryProvider);
  return SearchBooks(searchRepo: searchRepo, sourceRepo: sourceRepo);
});

/// 当前生效的搜索取消令牌：换词时由搜索页先 cancel 旧令牌再写入新令牌，
/// 保证旧批次的底层网络请求被真正中断。
class SearchCancelTokenNotifier extends Notifier<CancelToken?> {
  @override
  CancelToken? build() => null;

  void set(CancelToken? token) => state = token;
}

final searchCancelTokenProvider =
    NotifierProvider<SearchCancelTokenNotifier, CancelToken?>(
  SearchCancelTokenNotifier.new,
);

/// autoDispose：旧关键词不再被监听即销毁，避免被取消的旧批次（结果为 []）
/// 留在缓存中，用户重新搜索同一关键词时拿到的是新批次而非旧空结果。
final searchResultsProvider = FutureProvider.autoDispose
    .family<List<SearchResult>, String>((ref, keyword) async {
  if (keyword.trim().isEmpty) return [];
  final searchBooks = ref.watch(searchBooksProvider);
  // 仅在新批次启动时读取当前令牌；用 ref.read 而非 ref.watch，
  // 避免令牌更新触发旧关键词批次意外重启
  final cancelToken = ref.read(searchCancelTokenProvider);
  return searchBooks.executeMultiSource(keyword, cancelToken: cancelToken);
});
