import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:xml/xml.dart';

/// EPUB 书籍导入器 — 解析 EPUB 文件
class EpubImporter {
  /// 输入文件大小上限（zip bomb 防护，200MB）
  static const int _maxInputBytes = 200 * 1024 * 1024;
  /// 单章内容大小上限（10MB）
  static const int _maxChapterBytes = 10 * 1024 * 1024;
  /// 解压后总大小上限（1GB）
  static const int _maxTotalBytes = 1024 * 1024 * 1024;

  /// 解析 EPUB 文件，返回 (书名, 章节列表[(章节名, 内容)])
  static (String, List<(String, String)>) parseEpub(Uint8List bytes) {
    try {
      if (bytes.length > _maxInputBytes) return ('未命名书籍', []);
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.isEmpty) return ('未命名书籍', []);

      // zip bomb 防护：先按 zip 头声明的解压后大小拒绝，避免触发逐文件解压
      var totalBytes = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        totalBytes += f.size;
        if (totalBytes > _maxTotalBytes) return ('未命名书籍', []);
      }

      // 1. 读取 container.xml 定位 OPF 文件
      final containerFile = archive.files.firstWhere(
        (f) => f.name == 'META-INF/container.xml',
        orElse: () => throw const FormatException('无效的 EPUB：缺少 container.xml'),
      );
      final containerXml = XmlDocument.parse(utf8.decode(containerFile.content as List<int>));
      final rootfilePath = _extractRootfilePath(containerXml);

      // 2. 读取 OPF 文件获取元数据和目录
      final opfFile = _findFile(archive, rootfilePath);
      final opfXml = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));
      final title = _extractTitle(opfXml);
      final chapterFiles = _extractSpine(opfXml, archive, rootfilePath);

      // 3. 读取每个章节 XHTML
      final chapters = <(String, String)>[];
      for (final (chapterTitle, href) in chapterFiles) {
        try {
          final chapterFile = _findFile(archive, href);
          final content = chapterFile.content as List<int>;
          if (content.length > _maxChapterBytes) continue; // 跳过超大章节
          final htmlContent = utf8.decode(content);
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

  /// 解析 spine 章节顺序，并从 EPUB3 nav / EPUB2 NCX 提取章节标题
  static List<(String, String)> _extractSpine(XmlDocument opfXml, Archive archive, String opfPath) {
    final baseDir = _dirname(opfPath);
    final manifest = <String, String>{};
    String? navHref;
    for (final item in opfXml.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      final path = _joinPath(baseDir, href);
      manifest[id] = path;
      final props = item.getAttribute('properties') ?? '';
      if (props.split(' ').contains('nav')) navHref = path;
    }

    final spineHrefs = <String>[];
    // EPUB2 的 toc 属性位于 <spine> 元素上（指向 NCX 的 manifest id）
    String? tocId = opfXml.findAllElements('spine').firstOrNull?.getAttribute('toc');
    for (final itemref in opfXml.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      if (idref != null && manifest.containsKey(idref)) {
        spineHrefs.add(manifest[idref]!);
      }
    }
    if (spineHrefs.isEmpty) return [];

    final titles = _extractTitles(archive, navHref, tocId, manifest);

    return spineHrefs.map((href) => (titles[href] ?? '', href)).toList();
  }

  /// 提取章节标题映射（href → 标题）。EPUB3 nav 优先，EPUB2 NCX 兜底。
  static Map<String, String> _extractTitles(
    Archive archive,
    String? navHref,
    String? tocId,
    Map<String, String> manifest,
  ) {
    final titles = <String, String>{};

    // EPUB3: manifest properties="nav" 指向的导航文档
    if (navHref != null && navHref.isNotEmpty) {
      try {
        final file = _findFile(archive, navHref);
        final doc = parser.parse(utf8.decode(file.content as List<int>));
        for (final li in doc.querySelectorAll('nav li')) {
          final a = li.querySelector('a');
          if (a == null) continue;
          final href = a.attributes['href'] ?? '';
          final text = a.text.trim();
          if (href.isNotEmpty && text.isNotEmpty) {
            titles[_normalizeHref(navHref, href)] = text;
          }
        }
      } catch (_) {
        // 解析失败忽略，走 NCX 兜底
      }
    }

    // EPUB2: spine toc 属性指向的 NCX 文件
    if (titles.isEmpty && tocId != null) {
      final ncxPath = manifest[tocId];
      if (ncxPath != null) {
        try {
          final file = _findFile(archive, ncxPath);
          final ncxXml = XmlDocument.parse(utf8.decode(file.content as List<int>));
          for (final navPoint in ncxXml.findAllElements('navPoint')) {
            final label = navPoint.findAllElements('text').firstOrNull?.innerText.trim() ?? '';
            final src = navPoint.findAllElements('content').firstOrNull?.getAttribute('src') ?? '';
            if (label.isNotEmpty && src.isNotEmpty) {
              titles[_normalizeHref(ncxPath, src)] = label;
            }
          }
        } catch (_) {
          // 解析失败忽略
        }
      }
    }

    return titles;
  }

  /// 将文档内相对 href 解析为归档内绝对路径（去掉锚点片段）
  static String _normalizeHref(String docPath, String href) {
    final clean = href.split('#').first;
    return _joinPath(_dirname(docPath), clean);
  }

  /// 提取正文纯文本，保留段落/标题/换行结构
  static String _extractTextFromHtml(String html) {
    final doc = parser.parse(html);
    final body = doc.body;
    if (body == null) return '';
    final buffer = StringBuffer();
    _walk(body, buffer);
    return buffer.toString().trim();
  }

  static void _walk(dom.Node node, StringBuffer buffer) {
    if (node is dom.Text) {
      final text = node.text.trim();
      if (text.isNotEmpty) buffer.write(text);
      return;
    }
    if (node is dom.Element) {
      switch (node.localName) {
        case 'br':
          buffer.writeln();
          return;
        case 'p':
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
        case 'div':
        case 'section':
        case 'article':
          buffer.writeln();
          for (final child in node.nodes) {
            _walk(child, buffer);
          }
          buffer.writeln();
          return;
        default:
          for (final child in node.nodes) {
            _walk(child, buffer);
          }
          return;
      }
    }
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
