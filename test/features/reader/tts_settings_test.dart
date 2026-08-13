import 'dart:io';

import 'package:easy_read/features/reader/data/services/tts_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 拦截 flutter_tts 平台通道：记录调用参数并返回 null，避免真实平台调用
  const ttsChannel = MethodChannel('flutter_tts');
  final ttsCalls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ttsChannel, (call) async {
    ttsCalls.add(call);
    return null;
  });

  group('TtsService.setSpeechRate', () {
    test('默认语速 0.5，构造时应用到引擎', () {
      final service = TtsService();
      expect(service.speechRate, 0.5);
      expect(
        ttsCalls.any(
          (c) => c.method == 'setSpeechRate' && c.arguments == 0.5,
        ),
        isTrue,
      );
    });

    test('范围外输入 clamp 到 0.2-1.0 再传给引擎', () async {
      final service = TtsService();
      await service.setSpeechRate(0.1);
      expect(service.speechRate, 0.2);
      await service.setSpeechRate(2.0);
      expect(service.speechRate, 1.0);
      await service.setSpeechRate(0.8);
      expect(service.speechRate, 0.8);
      // 引擎最终收到的是 clamp 后的值
      expect(ttsCalls.last.arguments, 0.8);
    });

    test('speak 前应用当前语速', () async {
      final service = TtsService();
      await service.setSpeechRate(0.8);
      await service.speak('测试朗读');
      final speakIndex = ttsCalls.indexWhere((c) => c.method == 'speak');
      expect(speakIndex, isNot(-1));
      final lastRateBeforeSpeak = ttsCalls
          .sublist(0, speakIndex)
          .lastWhere((c) => c.method == 'setSpeechRate');
      expect(lastRateBeforeSpeak.arguments, 0.8);
    });
  });

  group('TtsService.setSleepTimer', () {
    test('到点自动停止并触发 onComplete', () async {
      final service = TtsService();
      var completed = 0;
      service.onComplete = () => completed++;
      service.setSleepTimer(const Duration(milliseconds: 50));
      expect(service.durationLeft, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(completed, 1);
      // 定时器已消费，剩余时间不可再查询
      expect(service.durationLeft, isNull);
    });

    test('重复设置重置定时器：旧定时器不再触发', () async {
      final service = TtsService();
      var completed = 0;
      service.onComplete = () => completed++;
      service.setSleepTimer(const Duration(seconds: 10));
      final leftBefore = service.durationLeft;
      service.setSleepTimer(const Duration(milliseconds: 50));
      expect(
        service.durationLeft!.inMilliseconds,
        lessThan(leftBefore!.inMilliseconds),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 仅新定时器触发；若未重置，旧 10s 定时器不会在这时触发
      expect(completed, 1);
    });

    test('stop 取消定时器', () async {
      final service = TtsService();
      var completed = 0;
      service.onComplete = () => completed++;
      service.setSleepTimer(const Duration(minutes: 15));
      expect(service.durationLeft, isNotNull);
      await service.stop();
      expect(service.durationLeft, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(completed, 0);
    });

    test('dispose 取消定时器', () async {
      final service = TtsService();
      var completed = 0;
      service.onComplete = () => completed++;
      service.setSleepTimer(const Duration(minutes: 15));
      await service.dispose();
      expect(service.durationLeft, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(completed, 0);
    });

    test('传 null 关闭定时停止', () async {
      final service = TtsService();
      var completed = 0;
      service.onComplete = () => completed++;
      service.setSleepTimer(const Duration(milliseconds: 50));
      service.setSleepTimer(null);
      expect(service.durationLeft, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(completed, 0);
    });
  });

  group('TtsSettings 持久化', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('hive_tts_settings');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('saveSettings/loadSettings 读写独立盒 tts_settings', () async {
      // 未设置时返回默认值：语速 0.5、无定时停止
      var settings = await TtsService.loadSettings();
      expect(settings.rate, 0.5);
      expect(settings.sleepMinutes, isNull);

      await TtsService.saveSettings(rate: 0.8, sleepMinutes: 30);
      settings = await TtsService.loadSettings();
      expect(settings.rate, 0.8);
      expect(settings.sleepMinutes, 30);

      // 关闭定时停止：键被删除，读取回 null
      await TtsService.saveSettings(rate: 0.6, sleepMinutes: null);
      settings = await TtsService.loadSettings();
      expect(settings.rate, 0.6);
      expect(settings.sleepMinutes, isNull);
    });

    test('loadSettings 对越界历史值做 clamp', () async {
      final box = await Hive.openBox<dynamic>(TtsService.settingsBoxName);
      await box.put('speechRate', 5.0);
      final settings = await TtsService.loadSettings();
      expect(settings.rate, 1.0);
    });
  });
}
