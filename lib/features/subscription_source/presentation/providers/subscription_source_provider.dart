import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/subscription_repository.dart';
import '../../data/services/subscription_source_service.dart';
import '../../domain/entities/subscription_source.dart';

/// 订阅源存储服务。
final subscriptionSourceServiceProvider = Provider<SubscriptionSourceService>(
  (ref) => SubscriptionSourceService(),
);

/// 订阅源拉取仓库（DioClient 默认单例）。
final subscriptionRepositoryProvider = Provider<SubscriptionRepository>(
  (ref) => SubscriptionRepository(
    service: ref.watch(subscriptionSourceServiceProvider),
  ),
);

/// 订阅源列表（写入后 invalidate 刷新）。
final subscriptionSourceListProvider =
    FutureProvider<List<SubscriptionSource>>((ref) {
  return ref.watch(subscriptionSourceServiceProvider).getAll();
});
