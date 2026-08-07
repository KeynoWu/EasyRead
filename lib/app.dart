import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';
import 'features/bookshelf/data/services/auto_refresh_service.dart';
import 'features/bookshelf/presentation/providers/bookshelf_provider.dart';
import 'features/reader/presentation/providers/reader_provider.dart';

class EasyReadApp extends ConsumerStatefulWidget {
  const EasyReadApp({super.key});

  @override
  ConsumerState<EasyReadApp> createState() => _EasyReadAppState();
}

class _EasyReadAppState extends ConsumerState<EasyReadApp> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final updater = BookshelfAutoUpdater(
        readerRepo: ref.read(readerRepositoryProvider),
        bookshelfRepo: ref.read(bookshelfRepositoryProvider),
        detailService: ref.read(bookDetailServiceProvider),
      );
      await AutoRefreshScheduler.restart(updater.updateAll);
    });
  }

  @override
  void dispose() {
    AutoRefreshScheduler.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
