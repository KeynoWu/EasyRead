/// 第三阶段：排版整理 — 统一段落格式、缩进、对齐
class LayoutPurifier {
  String purify(String input) {
    var result = input.trim();
    result = result.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    result = result.trim();
    return result;
  }
}
