import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:hive/hive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

/// TTS 听书服务
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  bool _stopRequested = false;
  Completer<void>? _stopCompleter;

  /// 当前语速（0.2-1.0，默认 0.5；持久化由调用方负责）
  double _speechRate = 0.5;
  /// 定时停止倒计时结束时刻；null 表示未开启
  DateTime? _sleepTimerEnd;
  /// 定时停止倒计时 Timer；null 表示未开启
  Timer? _sleepTimerTimer;
  /// 定时停止到点标记：防止 speak 循环收尾与定时器重复回调 [onComplete]
  bool _sleepTimerFired = false;

  /// 整章朗读完成回调（UI 用它复位播放状态）
  void Function()? onComplete;

  /// 单段朗读最大字符数：避免一次性 speak 超长文本被系统截断
  static const int maxChunkChars = 800;

  TtsService() {
    _tts.setLanguage('zh-CN');
    _tts.setSpeechRate(_speechRate);
    _tts.setVolume(1.0);
    // speak() 的 Future 在整段朗读完成后才 resolve，配合逐段 await 推进
    _tts.awaitSpeakCompletion(true);
  }

  bool get isSpeaking => _isSpeaking;

  /// 设置朗读语速（0.2-1.0）：超出范围自动 clamp 后再传给引擎。
  /// 持久化由调用方负责（见 [loadSettings]/[saveSettings]）。
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate.clamp(0.2, 1.0).toDouble();
    await _tts.setSpeechRate(_speechRate);
  }

  /// 当前语速（已 clamp 到 0.2-1.0）
  double get speechRate => _speechRate;

  /// 设置定时停止：非 null 时启动倒计时，读满 [duration] 后自动 [stop] 并触发
  /// [onComplete]（UI 据此复位播放状态）；重复设置会重置倒计时；传 null 关闭。
  /// 设置本身不影响正在进行的朗读，仅到点后停止。
  void setSleepTimer(Duration? duration) {
    _sleepTimerTimer?.cancel();
    _sleepTimerTimer = null;
    _sleepTimerEnd = null;
    if (duration == null || duration <= Duration.zero) return;
    _sleepTimerEnd = DateTime.now().add(duration);
    _sleepTimerTimer = Timer(duration, _onSleepTimerFired);
  }

  /// 定时停止剩余时间；未开启定时停止时为 null
  Duration? get durationLeft {
    final end = _sleepTimerEnd;
    if (end == null) return null;
    final remaining = end.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _onSleepTimerFired() {
    _sleepTimerFired = true;
    // 到点自动停止朗读并通知 UI 复位播放状态
    unawaited(stop());
    onComplete?.call();
  }

  void _cancelSleepTimer() {
    _sleepTimerTimer?.cancel();
    _sleepTimerTimer = null;
    _sleepTimerEnd = null;
  }

  /// 分段朗读：按句末标点切块后逐段 speak，避免整章一次性 4000 字符截断。
  /// 停止（stop/dispose）时通过 [_stopCompleter] 立即中断等待，不依赖平台
  /// 是否 resolve 挂起的 speak Future。
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final chunks = chunkText(text);
    if (chunks.isEmpty) return;
    // 每次朗读前应用当前语速，保证设置即时生效
    await _tts.setSpeechRate(_speechRate);
    _isSpeaking = true;
    _stopRequested = false;
    _sleepTimerFired = false;
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
    // 定时停止到点已回调过 onComplete，避免重复回调
    if (!_sleepTimerFired) {
      onComplete?.call();
    }
  }

  /// 暂停
  Future<void> pause() async {
    await _tts.pause();
  }

  /// 停止
  Future<void> stop() async {
    // 停止同时取消定时停止倒计时
    _cancelSleepTimer();
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

  /// 语速/定时停止设置独立持久化盒名（与阅读布局设置分离）
  static const String settingsBoxName = 'tts_settings';

  static Future<Box<dynamic>> _settingsBox() async =>
      Hive.openBox<dynamic>(settingsBoxName);

  /// 读取持久化的 TTS 设置；未设置过时返回默认语速 0.5、无定时停止。
  /// 实例方法不依赖 Hive（保持可测），读写由调用方（设置面板）负责。
  static Future<({double rate, int? sleepMinutes})> loadSettings() async {
    final box = await _settingsBox();
    final rate = ((box.get('speechRate') as num?)?.toDouble() ?? 0.5)
        .clamp(0.2, 1.0)
        .toDouble();
    final sleepMinutes = (box.get('sleepTimerMinutes') as num?)?.toInt();
    return (rate: rate, sleepMinutes: sleepMinutes);
  }

  /// 持久化 TTS 设置；[sleepMinutes] 为 null 表示关闭定时停止。
  static Future<void> saveSettings({
    required double rate,
    int? sleepMinutes,
  }) async {
    final box = await _settingsBox();
    await box.put('speechRate', rate);
    if (sleepMinutes != null) {
      await box.put('sleepTimerMinutes', sleepMinutes);
    } else {
      await box.delete('sleepTimerMinutes');
    }
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
