import 'package:easy_read/features/reader/data/services/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TtsService.toPlainText', () {
    test('去除 HTML 标签，保留正文文本', () {
      final plain = TtsService.toPlainText(
        '<p>第一段<b>加粗</b></p><p>第二段</p>',
      );
      expect(plain, contains('第一段'));
      expect(plain, contains('加粗'));
      expect(plain, contains('第二段'));
      expect(plain, isNot(contains('<p>')));
      expect(plain, isNot(contains('</p>')));
    });

    test('跳过 script/style 文本', () {
      final plain = TtsService.toPlainText(
        '<script>var x = 1;</script><p>正文内容</p>',
      );
      expect(plain, '正文内容');
      expect(plain, isNot(contains('var x')));
    });

    test('空内容与非法片段兜底不崩溃', () {
      expect(TtsService.toPlainText(''), isEmpty);
      expect(TtsService.toPlainText('纯文本'), '纯文本');
    });
  });

  group('TtsService.chunkText', () {
    test('短文本不切块', () {
      expect(TtsService.chunkText('短文本'), ['短文本']);
    });

    test('长文本按句末标点切块且每块不超上限', () {
      final text = List.filled(150, '这是第一句话。').join();
      final chunks = TtsService.chunkText(text);
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(TtsService.maxChunkChars));
      }
      expect(chunks.join(), text);
    });
  });
}
