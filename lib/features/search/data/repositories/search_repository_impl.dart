import '../../../../core/network/dio_client.dart';
import '../../../../core/purification/purify_pipeline.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/search_repository.dart';

class SearchRepositoryImpl implements SearchRepository {
  final DioClient _client;
  final PurifyPipeline _pipeline;

  SearchRepositoryImpl({DioClient? client, PurifyPipeline? pipeline})
      : _client = client ?? DioClient(),
        _pipeline = pipeline ?? PurifyPipeline();

  @override
  Future<List<SearchResult>> search(String keyword, String sourceId) async {
    // Phase 2 实现完整的书源规则解析
    return [];
  }
}
