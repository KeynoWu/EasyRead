import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/pagination/page_layout.dart';
import '../../core/parser/node_tree.dart';
import '../providers/reader_provider.dart';
class ReaderPageView extends ConsumerWidget {
  const ReaderPageView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerProvider);
    final notifier = ref.read(readerProvider.notifier);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.pages.isEmpty) {
      return const Center(child: Text('暂无内容'));
    }

    return GestureDetector(
      onTap: notifier.toggleSettings,
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -100) {
            notifier.nextPage();
          } else if (details.primaryVelocity! > 100) {
            notifier.prevPage();
          }
        }
      },
      child: Container(
        color: state.theme.backgroundColor,
        child: Column(
          children: [
            Expanded(
              child: _buildPageContent(state.pages[state.currentPage], state),
            ),
            // 进度条
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: state.theme.backgroundColor,
              child: Row(
                children: [
                  Text(
                    '${state.currentPage + 1}/${state.pages.length}',
                    style: TextStyle(color: state.theme.textColor, fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (state.currentPage + 1) / state.pages.length,
                        backgroundColor: state.theme.textColor.withOpacity(0.2),
                        color: Colors.blue,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageContent(PageContent page, ReaderState state) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: state.layoutConfig.horizontalPadding),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: page.nodes.map((node) {
            switch (node.type) {
              case NodeType.paragraph:
                return Padding(
                  padding: EdgeInsets.only(bottom: state.layoutConfig.paragraphSpacing),
                  child: Text(
                    node.text,
                    style: TextStyle(
                      fontSize: state.layoutConfig.fontSize,
                      height: state.layoutConfig.lineHeight,
                      color: state.theme.textColor,
                    ),
                  ),
                );
              case NodeType.heading:
                return Padding(
                  padding: EdgeInsets.only(bottom: state.layoutConfig.paragraphSpacing),
                  child: Text(
                    node.text,
                    style: TextStyle(
                      fontSize: state.layoutConfig.fontSize + 4,
                      fontWeight: FontWeight.w700,
                      color: state.theme.textColor,
                    ),
                  ),
                );
              case NodeType.lineBreak:
                return const SizedBox(height: 8);
              case NodeType.text:
                return Text(
                  node.text,
                  style: TextStyle(
                    fontSize: state.layoutConfig.fontSize,
                    height: state.layoutConfig.lineHeight,
                    color: state.theme.textColor,
                  ),
                );
              case NodeType.image:
                return Container(
                  height: 200,
                  color: state.theme.textColor.withOpacity(0.1),
                  child: const Center(child: Icon(Icons.image, size: 48)),
                );
            }
          }).toList(),
        ),
      ),
    );
  }
}
