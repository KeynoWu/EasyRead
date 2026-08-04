import 'dart:convert';
import 'dart:typed_data';
import 'package:fast_gbk/fast_gbk.dart';

/// TXT 书籍导入器 — 解析章节并返回章节列表
class TxtImporter {
  /// 识别编码并解析 TXT 内容
  /// 返回 (书名, 章节列表[(章节名, 内容)])
  static (String, List<(String, String)>) parseTxt(
    Uint8List bytes,
    String fileName,
  ) {
    final content = _decode(bytes);
    final title = _extractTitle(fileName, content);
    final chapters = _extractChapters(content);
    return (title, chapters);
  }

  /// 编码识别：UTF-8 优先，失败则尝试 GBK/GB18030（国内小说 TXT 常见编码），
  /// 最后 Latin1 兜底。
  static String _decode(Uint8List bytes) {
    // 尝试 UTF-8（严格模式，失败说明不是合法 UTF-8）
    try {
      final utf8Decoded = utf8.decode(bytes, allowMalformed: false);
      if (utf8Decoded.isNotEmpty) return utf8Decoded;
    } catch (_) {
      // fall through
    }

    // GBK/GB18030（fast_gbk 对任意字节流均能解码，中文场景正确还原）
    try {
      return gbk.decode(bytes);
    } catch (_) {
      // fall through
    }

    // Latin1 兜底（纯单字节场景）
    return latin1.decode(bytes, allowInvalid: true);
  }

  /// 从文件名提取书名
  static String _extractTitle(String fileName, String content) {
    final base = fileName.replaceAll(RegExp(r'\.(txt|TXT)$'), '');
    if (base.isNotEmpty) return base;
    return '未命名书籍';
  }

  /// 解析章节标题（匹配常见章节格式）
  static List<(String, String)> _extractChapters(String content) {
    final lines = content.split(RegExp(r'\r\n|\n'));
    final chapters = <(String, String)>[];
    final buffer = StringBuffer();
    var currentTitle = '正文';
    final chapterPattern = RegExp(
      r'^\s*(第[0-9一二三四五六七八九十百千万零〇两]+[章节卷回集部篇]|Chapter\s+\d+|CHAPTER\s+\d+|序章|楔子|序言|番外|尾声|后记)\s*.*$',
    );

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && chapterPattern.hasMatch(trimmed)) {
        // 保存上一章
        if (buffer.toString().trim().isNotEmpty) {
          chapters.add((currentTitle, buffer.toString().trim()));
        }
        currentTitle = trimmed;
        buffer.clear();
      } else {
        buffer.writeln(line);
      }
    }

    // 保存最后一章
    if (buffer.toString().trim().isNotEmpty) {
      chapters.add((currentTitle, buffer.toString().trim()));
    }

    if (chapters.isEmpty) {
      chapters.add(('正文', content.trim()));
    }
    return chapters;
  }
}
