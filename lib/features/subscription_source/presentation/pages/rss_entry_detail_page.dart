import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 条目详情页：InAppWebView 加载条目链接，加载失败（SSL/网络）显示错误文案。
class RssEntryDetailPage extends StatefulWidget {
  final String url;
  final String title;

  const RssEntryDetailPage({super.key, required this.url, required this.title});

  @override
  State<RssEntryDetailPage> createState() => _RssEntryDetailPageState();
}

class _RssEntryDetailPageState extends State<RssEntryDetailPage> {
  String? _error;
  int _progress = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          if (_progress > 0 && _progress < 100 && _error == null)
            LinearProgressIndicator(value: _progress / 100),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (widget.url.isEmpty) {
      return const Center(child: Text('条目没有可访问的链接'));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => setState(() => _error = null),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      onProgressChanged: (controller, progress) {
        if (mounted) setState(() => _progress = progress);
      },
      onReceivedError: (controller, request, error) {
        // 仅主框架错误视为页面级失败，忽略子资源错误
        if (request.isForMainFrame == true && mounted) {
          setState(() => _error = '页面加载失败：${error.description}');
        }
      },
    );
  }
}
