import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

/// TTS 听书服务
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  bool _stopRequested = false;
  Completer<void>? _stopCompleter;

  /// 整章朗读完成回调（UI 用它复位播放状态）
  void Function()? onComplete;

  /// 单段朗读最大字符数：避免一次性 speak 超长文本被系统截断
  static const int maxChunkChars = 800;

  TtsService() {
    _tts.setLanguage('zh-CN');
    _tts.setSpeechRate(0.5);
    _tts.setVolume(1.0);
    // speak() 的 Future 在整段朗读完成后才 resolve，配合逐段 await 推进
    _tts.awaitSpeakCompletion(true);
  }

  bool get isSpeaking => _isSpeaking;

  /// 分段朗读：按句末标点切块后逐段 speak，避免整章一次性 4000 字符截断。
  /// 停止（stop/dispose）时通过 [_stopCompleter] 立即中断等待，不依赖平台
  /// 是否 resolve 挂起的 speak Future。
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final chunks = chunkText(text);
    if (chunks.isEmpty) return;
    _isSpeaking = true;
    _stopRequested = false;
    final stopCompleter = Completer<void>();
    _stopCompleter = stopCompleter;
    for (final chunk in chunks) {
      if (_stopRequested) break;
      try {
        await Future.any([
          _tts.speak(chunk),
          stopCompleter.future,
        ]);
      } catch (_) {
        // 单段朗读失败：停止后续段落，避免卡死
        break;
      }
    }
    _isSpeaking = false;
    onComplete?.call();
  }

  /// 暂停
  Future<void> pause() async {
    await _tts.pause();
  }

  /// 停止
  Future<void> stop() async {
    _stopRequested = true;
    _isSpeaking = false;
    _stopCompleter?.complete();
    _stopCompleter = null;
    try {
      await _tts.stop();
    } catch (_) {
      // 平台停止失败不影响状态复位
    }
  }

  /// 释放资源（阅读页退出时调用）：停止朗读并清空回调，防止离页后回调 UI。
  Future<void> dispose() async {
    onComplete = null;
    await stop();
  }

  /// 将净化后的 HTML 正文转为纯文本（跳过脚本/样式，保留段落换行）。
  /// TTS 朗读使用该文本，避免把标签名读出来。
  static String toPlainText(String html) {
    try {
      final doc = parser.parse(html);
      final body = doc.body;
      if (body == null) return html.trim();
      final buffer = StringBuffer();
      _collectPlainText(body, buffer);
      return buffer.toString().trim();
    } catch (_) {
      return html.trim();
    }
  }

  static void _collectPlainText(dom.Node node, StringBuffer buffer) {
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is dom.Element) {
      switch (node.localName) {
        case 'script':
        case 'style':
        case 'noscript':
        case 'template':
          return;
        case 'br':
          buffer.writeln();
          return;
        case 'p':
        case 'div':
        case 'section':
        case 'article':
        case 'li':
        case 'blockquote':
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          buffer.writeln();
          for (final child in node.nodes) {
            _collectPlainText(child, buffer);
          }
          buffer.writeln();
          return;
        default:
          for (final child in node.nodes) {
            _collectPlainText(child, buffer);
          }
      }
    }
  }

  /// 按不超过 [maxChunkChars] 字符切块，优先在句末标点 / 换行边界断开。
  static List<String> chunkText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.length <= maxChunkChars) return [trimmed];

    final chunks = <String>[];
    final buffer = StringBuffer();
    for (final part in trimmed.split(RegExp(r'(?<=[。！？；\n])'))) {
      if (buffer.length + part.length > maxChunkChars && buffer.isNotEmpty) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      buffer.write(part);
      if (buffer.length >= maxChunkChars) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) {
      chunks.add(buffer.toString().trim());
    }
    return chunks.where((c) => c.isNotEmpty).toList();
  }
}
