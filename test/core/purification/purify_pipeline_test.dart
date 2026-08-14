import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/core/purification/purify_pipeline.dart';

void main() {
  test('full pipeline should clean HTML end-to-end', () async {
    const input = '''
      <div class="ad">广告</div>
      <script>alert("x")</script>
      <p>正文内容，包含标点</p>
      <style>.ad{display:none}</style>
    ''';
    final pipeline = PurifyPipeline();
    final result = await pipeline.purifyAsync(input);
    expect(result, isNot(contains('广告')));
    expect(result, isNot(contains('alert')));
    expect(result, isNot(contains('display:none')));
    expect(result, contains('正文内容'));
  });
}
