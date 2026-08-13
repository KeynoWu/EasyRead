import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';
import 'features/bookshelf/data/services/auto_refresh_service.dart';
import 'features/bookshelf/presentation/providers/bookshelf_provider.dart';
import 'features/book_source/presentation/providers/book_source_provider.dart';
import 'features/reader/presentation/providers/reader_provider.dart';
import 'features/settings/data/services/webdav_backup_scheduler.dart';
import 'features/settings/domain/usecases/backup_restore.dart';

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
      // WebDAV 自动备份：enabled 且已配置时启动，未开启则静默跳过
      await WebDavBackupScheduler.start(
        backupRestore: BackupRestore(
          bookshelfRepo: ref.read(bookshelfRepositoryProvider),
          sourceRepo: ref.read(bookSourceRepositoryProvider),
        ),
      );
    });
  }

  @override
  void dispose() {
    AutoRefreshScheduler.stop();
    WebDavBackupScheduler.stop();
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
