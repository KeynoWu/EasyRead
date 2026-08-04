import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as parser;
import 'package:xml/xml.dart';

/// EPUB 书籍导入器 — 解析 EPUB 文件
class EpubImporter {
  /// 解析 EPUB 文件，返回 (书名, 章节列表[(章节名, 内容)])
  static (String, List<(String, String)>) parseEpub(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.isEmpty) return ('未命名书籍', []);

      // 1. 读取 container.xml 定位 OPF 文件
      final containerFile = archive.files.firstWhere(
        (f) => f.name == 'META-INF/container.xml',
        orElse: () => throw FormatException('无效的 EPUB：缺少 container.xml'),
      );
      final containerXml = XmlDocument.parse(utf8.decode(containerFile.content as List<int>));
      final rootfilePath = _extractRootfilePath(containerXml);

      // 2. 读取 OPF 文件获取元数据和目录
      final opfFile = _findFile(archive, rootfilePath);
      final opfXml = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));
      final title = _extractTitle(opfXml);
      final chapterFiles = _extractSpine(opfXml, rootfilePath);

      // 3. 读取每个章节 XHTML
      final chapters = <(String, String)>[];
      for (final (chapterTitle, href) in chapterFiles) {
        try {
          final chapterFile = _findFile(archive, href);
          final htmlContent = utf8.decode(chapterFile.content as List<int>);
          final text = _extractTextFromHtml(htmlContent);
          if (text.isNotEmpty) {
            chapters.add((chapterTitle.isEmpty ? '第${chapters.length + 1}节' : chapterTitle, text));
          }
        } catch (_) {
          // 跳过无法解析的章节
        }
      }

      return (title, chapters);
    } catch (e) {
      return ('未命名书籍', []);
    }
  }

  static String _extractRootfilePath(XmlDocument containerXml) {
    final rootfile = containerXml.findAllElements('rootfile').first;
    return rootfile.getAttribute('full-path') ?? '';
  }

  static String _extractTitle(XmlDocument opfXml) {
    final title = opfXml.findAllElements('title');
    if (title.isNotEmpty) return title.first.innerText.trim();
    final dcTitle = opfXml.findAllElements('dc:title');
    if (dcTitle.isNotEmpty) return dcTitle.first.innerText.trim();
    return '未命名书籍';
  }

  static List<(String, String)> _extractSpine(XmlDocument opfXml, String opfPath) {
    final baseDir = _dirname(opfPath);
    final manifest = <String, String>{};
    for (final item in opfXml.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifest[id] = _joinPath(baseDir, href);
      }
    }

    final result = <(String, String)>[];
    for (final itemref in opfXml.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      if (idref != null && manifest.containsKey(idref)) {
        result.add(('', manifest[idref]!));
      }
    }
    return result;
  }

  static String _extractTextFromHtml(String html) {
    final doc = parser.parse(html);
    final body = doc.body;
    if (body == null) return '';
    return body.text.trim();
  }

  static ArchiveFile _findFile(Archive archive, String path) {
    final normalized = path.replaceAll('\\', '/');
    for (final file in archive.files) {
      if (file.name == normalized || file.name.replaceAll('\\', '/') == normalized) {
        return file;
      }
    }
    // 尝试去除前导 /
    final stripped = normalized.replaceFirst(RegExp(r'^/+'), '');
    for (final file in archive.files) {
      if (file.name.replaceAll('\\', '/') == stripped) {
        return file;
      }
    }
    throw FormatException('文件不存在: $path');
  }

  static String _dirname(String path) {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? '' : path.substring(0, idx);
  }

  static String _joinPath(String base, String href) {
    if (href.startsWith('/')) return href.substring(1);
    if (base.isEmpty) return href;
    return '$base/$href';
  }
}
