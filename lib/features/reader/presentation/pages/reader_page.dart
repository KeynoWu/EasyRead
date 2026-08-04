import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/reader_provider.dart';
import '../widgets/page_view_widget.dart';
import '../widgets/reader_settings_panel.dart';

class ReaderPage extends ConsumerStatefulWidget {
  final String bookId;

  const ReaderPage({super.key, required this.bookId});

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(readerProvider.notifier).loadChapter(
        bookId: widget.bookId,
        chapterIndex: 0,
        sourceId: 'default',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);

    return Scaffold(
      backgroundColor: state.theme.backgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            // 阅读区域
            Column(
              children: [
                // 顶部导航栏
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: state.theme.backgroundColor,
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back, color: state.theme.textColor),
                        onPressed: () => context.pop(),
                      ),
                      const Spacer(),
                      if (state.currentChapter != null)
                        Text(
                          state.currentChapter!.title,
                          style: TextStyle(color: state.theme.textColor, fontSize: 14),
                        ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(Icons.settings, color: state.theme.textColor),
                        onPressed: () => ref.read(readerProvider.notifier).toggleSettings(),
                      ),
                    ],
                  ),
                ),
                // 阅读内容
                Expanded(child: ReaderPageView()),
              ],
            ),
            // 设置面板
            if (state.showSettings)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ReaderSettingsPanel(),
              ),
          ],
        ),
      ),
    );
  }
}
