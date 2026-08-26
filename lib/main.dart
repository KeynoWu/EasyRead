import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/database/hive_init.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局兜底：release 下异步未捕获异常不再静默进控制台
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[未捕获异常] $error\n$stack');
    return true;
  };
  Object? initError;
  try {
    await initHive();
  } catch (e, s) {
    // 存储初始化失败（密钥损坏/盒损坏且无法自动修复）：给可读错误页，
    // 而非白屏或启动崩溃循环
    debugPrint('[启动失败] initHive: $e\n$s');
    initError = e;
  }
  runApp(ProviderScope(
    child: initError == null
        ? const EasyReadApp()
        : StartupErrorApp(error: initError),
  ));
}

/// 存储初始化失败时的错误页：展示原因并提供重试（密钥瞬时不可用时有效）。
class StartupErrorApp extends StatelessWidget {
  final Object? error;
  const StartupErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text('数据存储初始化失败', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 24),
                const FilledButton(
                  onPressed: main, // 重试：重新走一遍启动流程
                  child: Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
