import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/reader_provider.dart';

/// 会话级封面加载失败缓存（Legado OkHttpStreamFetcher.containFailureImage
/// 语义）：防盗链等必然失败的 URL 不重复请求，避免请求风暴。
final Set<String> _failedCoverUrls = {};

/// 带防盗链支持的封面图（§三-3）：优先经书源 headers + cookie 取图
/// （ReaderRepositoryImpl.fetchImageBytes → DioClient.getBytes 完整网络
/// 管线），失败回退占位图标；[usePlainNetwork] 供无书源上下文的调用方
/// 退回 Image.network。
class CoverImage extends ConsumerStatefulWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.sourceId,
    this.width,
    this.height,
    this.borderRadius,
    this.fallbackIcon = const Icon(Icons.auto_stories, size: 40),
  });

  final String url;
  final String? sourceId;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Widget fallbackIcon;

  @override
  ConsumerState<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<CoverImage> {
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.sourceId != widget.sourceId) {
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url.isEmpty || _failedCoverUrls.contains(url)) return;
    setState(() => _loading = true);
    try {
      final bytes = await ref
          .read(readerRepositoryProvider)
          .fetchImageBytes(url, sourceId: widget.sourceId);
      if (!mounted || url != widget.url) return;
      if (bytes.isEmpty) {
        _failedCoverUrls.add(url);
      } else {
        setState(() => _bytes = bytes);
      }
    } catch (_) {
      _failedCoverUrls.add(url);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_bytes != null) {
      child = Image.memory(
        _bytes!,
        fit: BoxFit.cover,
        width: widget.width,
        height: widget.height,
      );
    } else if (_loading) {
      child = SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else {
      child = SizedBox(
        width: widget.width,
        height: widget.height,
        child: Center(child: widget.fallbackIcon),
      );
    }
    if (widget.borderRadius != null) {
      child = ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }
    return child;
  }
}
