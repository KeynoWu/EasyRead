import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../../core/data/cookie_jar_service.dart';
import '../../domain/entities/book_source.dart';

/// WebView 登录书源：用户完成站点登录后点击“完成登录”，
/// 读取当前站点 Cookie 并写入 CookieJar，供搜索/详情/正文请求自动携带。
class BookSourceLoginPage extends StatefulWidget {
  final BookSource source;

  const BookSourceLoginPage({super.key, required this.source});

  @override
  State<BookSourceLoginPage> createState() => _BookSourceLoginPageState();

  /// 解析登录页初始 URL：支持相对路径与 Legado `URL,{json参数}` 写法。
  @visibleForTesting
  static String? resolveLoginUrl(BookSource source) {
    final base = source.bookSourceUrl;
    final raw = source.loginUrl?.trim() ?? '';
    var path = raw.isEmpty ? (base ?? '') : raw;
    final comma = path.indexOf(',{');
    if (comma > 0) {
      path = path.substring(0, comma).trim();
    }
    if (path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    if (base == null || base.isEmpty) return path;
    return Uri.parse(base).resolve(path).toString();
  }
}

class _BookSourceLoginPageState extends State<BookSourceLoginPage> {
  InAppWebViewController? _controller;
  String? _initialUrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialUrl = BookSourceLoginPage.resolveLoginUrl(widget.source);
  }

  Future<void> _finishLogin() async {
    final controller = _controller;
    final url = _initialUrl;
    if (controller == null || url == null) {
      _showMessage('登录页尚未加载完成');
      return;
    }
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
      if (cookies.isEmpty) {
        _showMessage('未获取到登录 Cookie，请先完成登录');
        return;
      }
      final cookie = cookies
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      await CookieJarService().set(widget.source.id, cookie);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      _showMessage('读取 Cookie 失败，请重试');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _initialUrl;
    return Scaffold(
      appBar: AppBar(
        title: Text('登录 ${widget.source.name}'),
        actions: [
          TextButton(
            onPressed: _finishLogin,
            child: const Text('完成登录'),
          ),
        ],
      ),
      body: url == null
          ? const Center(child: Text('书源未配置可访问的登录地址'))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 48),
                      const SizedBox(height: 12),
                      Text(_error!),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => setState(() => _error = null),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(url)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    thirdPartyCookiesEnabled: true,
                  ),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                  },
                  onReceivedError: (controller, request, error) {
                    if (mounted) {
                      setState(() => _error = '页面加载失败：${error.description}');
                    }
                  },
                ),
    );
  }
}
