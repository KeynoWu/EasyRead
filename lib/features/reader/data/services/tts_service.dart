import 'package:flutter_tts/flutter_tts.dart';

/// TTS 听书服务
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;

  TtsService() {
    _tts.setLanguage('zh-CN');
    _tts.setSpeechRate(0.5);
    _tts.setVolume(1.0);
  }

  bool get isSpeaking => _isSpeaking;

  /// 播放文本
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    _isSpeaking = true;
    await _tts.speak(text);
  }

  /// 暂停
  Future<void> pause() async {
    await _tts.pause();
  }

  /// 停止
  Future<void> stop() async {
    _isSpeaking = false;
    await _tts.stop();
  }
}
