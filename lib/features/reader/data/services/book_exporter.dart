import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import '../../domain/entities/chapter_catalog.dart';
import 'book_cache_service.dart';
import 'tts_service.dart';

/// 保存回调：默认走 FilePicker 弹窗；测试注入假实现以脱离平台通道
typedef BookSaveFile = Future<String?> Function(
    Uint8List bytes, String fileName);

/// 导出前置校验失败：书未缓存或缓存数据来自其它书源
class ExportSourceMismatchException implements Exception {
  final String message;

  const ExportSourceMismatchException(
      [this.message = '缓存缺失或书源已变化，请重新缓存后再导出']);

  @override
  String toString() => message;
}

/// 导出结果
class ExportResult {
  /// 保存路径；用户取消保存时为 null
  final String? path;

  /// 实际导出的章节数
  final int exported;

  /// 未缓存跳过的章节数
  final int skipped;

  const ExportResult({this.path, required this.exported, required this.skipped});
}

/// 整本导出：从整本缓存盒读取章节，生成 TXT / EPUB 文件。
///
/// 导出前校验 [BookCacheBox] 元数据中的 sourceId 与当前书源一致，
/// 不一致抛 [ExportSourceMismatchException]，避免换源后导出旧书源内容。
class BookExporter {
  final BookSaveFile _saveFile;

  BookExporter({BookSaveFile? saveFile})
      : _saveFile = saveFile ?? _defaultSaveFile;

  static Future<String?> _defaultSaveFile(Uint8List bytes, String fileName) {
    return FilePicker.platform.saveFile(
      dialogTitle: '导出文件',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [fileName.split('.').last],
      bytes: bytes,
    );
  }

  /// 导出 TXT：书名/作者头 + 每章 `标题\n正文纯文本\n\n`。
  /// 未缓存章节跳过并计数；用户取消保存时 [ExportResult.path] 为 null。
  Future<ExportResult> exportTxt({
    required String bookId,
    required String sourceId,
    required String bookName,
    String? author,
    required List<ChapterItem> chapters,
  }) async {
    await _validateSource(bookId, sourceId);
    final buffer = StringBuffer();
    buffer.writeln(bookName);
    buffer.writeln(author ?? '');
    buffer.writeln();
    var exported = 0;
    var skipped = 0;
    for (final item in chapters) {
      final html = await BookCacheBox.readChapter(bookId, item.index);
      if (html == null || html.trim().isEmpty) {
        skipped++;
        continue;
      }
      buffer.writeln(item.title);
      buffer.writeln(TtsService.toPlainText(html));
      buffer.writeln();
      exported++;
    }
    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final path = await _saveFile(bytes, '$bookName.txt');
    return ExportResult(path: path, exported: exported, skipped: skipped);
  }

  /// 导出 EPUB3（含 EPUB2 兼容 toc.ncx）：
  /// mimetype 必须为压缩包第一项且 STORED 不压缩；container.xml 指向
  /// OEBPS/content.opf；spine 按章节顺序排列。
  Future<ExportResult> exportEpub({
    required String bookId,
    required String sourceId,
    required String bookName,
    String? author,
    required List<ChapterItem> chapters,
  }) async {
    await _validateSource(bookId, sourceId);
    final entries = <_ChapterEntry>[];
    var skipped = 0;
    for (final item in chapters) {
      final html = await BookCacheBox.readChapter(bookId, item.index);
      if (html == null || html.trim().isEmpty) {
        skipped++;
        continue;
      }
      entries.add(_ChapterEntry(
        title: item.title,
        xhtml: _chapterXhtml(item.title, _toXhtmlFragment(html)),
      ));
    }

    final archive = Archive();
    // mimetype 必须为压缩包第一项且不压缩（EPUB 规范）
    final mimetypeBytes = utf8.encode('application/epub+zip');
    archive.addFile(ArchiveFile.noCompress(
        'mimetype', mimetypeBytes.length, mimetypeBytes));
    archive.addFile(
        ArchiveFile.string('META-INF/container.xml', _containerXml()));
    archive.addFile(
        ArchiveFile.string('OEBPS/nav.xhtml', _navXml(bookName, entries)));
    archive.addFile(
        ArchiveFile.string('OEBPS/toc.ncx', _ncxXml(bookName, entries)));
    archive.addFile(
        ArchiveFile.string('OEBPS/content.opf', _opfXml(bookName, author, entries)));
    for (var i = 0; i < entries.length; i++) {
      archive.addFile(
          ArchiveFile.string('OEBPS/${_chapterFile(i)}', entries[i].xhtml));
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final path = await _saveFile(bytes, '$bookName.epub');
    return ExportResult(path: path, exported: entries.length, skipped: skipped);
  }

  /// 校验缓存书源：meta.sourceId 必须与当前书源一致
  Future<void> _validateSource(String bookId, String sourceId) async {
    final meta = await BookCacheBox.readMeta(bookId);
    if (meta == null || meta['sourceId'] != sourceId) {
      throw const ExportSourceMismatchException();
    }
  }

  /// 章节文件名：chapter_0001.xhtml
  static String _chapterFile(int index) =>
      'chapter_${(index + 1).toString().padLeft(4, '0')}.xhtml';

  /// 单章 xhtml：标题作 <h2> 页内标题，净化片段嵌入正文
  static String _chapterXhtml(String title, String fragment) {
    final escaped = _xmlEscape(title);
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">\n'
        '<head><title>$escaped</title></head>\n'
        '<body>\n'
        '<h2>$escaped</h2>\n'
        '$fragment\n'
        '</body>\n'
        '</html>\n';
  }

  /// 净化后 HTML（或纯文本）转 xhtml 片段：
  /// - 可解析出元素 → 剔除 script/style 后嵌入原片段；
  /// - 纯文本/解析失败 → 转义后包一层 <p>，保证 xhtml 合法。
  static String _toXhtmlFragment(String html) {
    final trimmed = html.trim();
    if (trimmed.isEmpty) return '';
    try {
      final doc = parser.parse(trimmed);
      final body = doc.body;
      if (body == null) return '<p>${_xmlEscape(trimmed)}</p>';
      final elements = body.children.whereType<dom.Element>().toList();
      if (elements.isEmpty) {
        return '<p>${_xmlEscape(body.text)}</p>';
      }
      for (final element in elements) {
        if (element.localName == 'script' || element.localName == 'style') {
          element.remove();
        }
      }
      return body.innerHtml;
    } catch (_) {
      return '<p>${_xmlEscape(trimmed)}</p>';
    }
  }

  static String _containerXml() {
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
        '  <rootfiles>\n'
        '    <rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/>\n'
        '  </rootfiles>\n'
        '</container>\n';
  }

  static String _opfXml(
      String bookName, String? author, List<_ChapterEntry> entries) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<package xmlns="http://www.idpf.org/2007/opf" '
        'version="3.0" unique-identifier="book-id" xml:lang="zh">');
    buffer.writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:opf="http://www.idpf.org/2007/opf">');
    buffer.writeln(
        '    <dc:identifier id="book-id">urn:uuid:${_uuidFor(bookName)}</dc:identifier>');
    buffer.writeln('    <dc:title>${_xmlEscape(bookName)}</dc:title>');
    if (author != null && author.isNotEmpty) {
      buffer.writeln(
          '    <dc:creator opf:role="aut">${_xmlEscape(author)}</dc:creator>');
    }
    buffer.writeln('    <dc:language>zh</dc:language>');
    buffer.writeln('    <meta property="dcterms:modified">'
        '${DateTime.now().toUtc().toIso8601String()}</meta>');
    buffer.writeln('  </metadata>');
    buffer.writeln('  <manifest>');
    buffer.writeln('    <item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>');
    buffer.writeln('    <item id="ncx" href="toc.ncx" '
        'media-type="application/x-dtbncx+xml"/>');
    for (var i = 0; i < entries.length; i++) {
      buffer.writeln('    <item id="${_chapterId(i)}" '
          'href="${_chapterFile(i)}" media-type="application/xhtml+xml"/>');
    }
    buffer.writeln('  </manifest>');
    buffer.writeln('  <spine toc="ncx">');
    for (var i = 0; i < entries.length; i++) {
      buffer.writeln('    <itemref idref="${_chapterId(i)}"/>');
    }
    buffer.writeln('  </spine>');
    buffer.writeln('</package>');
    return buffer.toString();
  }

  static String _navXml(String bookName, List<_ChapterEntry> entries) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh">');
    buffer.writeln('<head><title>${_xmlEscape(bookName)}</title></head>');
    buffer.writeln('<body>');
    buffer.writeln('<nav epub:type="toc">');
    buffer.writeln('<h1>${_xmlEscape(bookName)}</h1>');
    buffer.writeln('<ol>');
    for (var i = 0; i < entries.length; i++) {
      buffer.writeln('  <li><a href="${_chapterFile(i)}">'
          '${_xmlEscape(entries[i].title)}</a></li>');
    }
    buffer.writeln('</ol>');
    buffer.writeln('</nav>');
    buffer.writeln('</body>');
    buffer.writeln('</html>');
    return buffer.toString();
  }

  static String _ncxXml(String bookName, List<_ChapterEntry> entries) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" '
        'version="2005-1">');
    buffer.writeln('  <head>');
    buffer.writeln('    <meta name="dtb:uid" content="${_uuidFor(bookName)}"/>');
    buffer.writeln('    <meta name="dtb:depth" content="1"/>');
    buffer.writeln('    <meta name="dtb:totalPageCount" content="0"/>');
    buffer.writeln('    <meta name="dtb:maxPageNumber" content="0"/>');
    buffer.writeln('  </head>');
    buffer.writeln('  <docTitle><text>${_xmlEscape(bookName)}</text></docTitle>');
    buffer.writeln('  <navMap>');
    for (var i = 0; i < entries.length; i++) {
      buffer.writeln('    <navPoint id="nav${i + 1}" playOrder="${i + 1}">');
      buffer.writeln('      <navLabel><text>${_xmlEscape(entries[i].title)}</text></navLabel>');
      buffer.writeln('      <content src="${_chapterFile(i)}"/>');
      buffer.writeln('    </navPoint>');
    }
    buffer.writeln('  </navMap>');
    buffer.writeln('</ncx>');
    return buffer.toString();
  }

  static String _chapterId(int index) =>
      'chapter_${(index + 1).toString().padLeft(4, '0')}';

  /// 由书名派生稳定的 UUID v4 形态标识（无需额外依赖）
  static String _uuidFor(String seed) {
    final hash = md5.convert(utf8.encode(seed)).toString();
    return '${hash.substring(0, 8)}-${hash.substring(8, 12)}-'
        '${hash.substring(12, 16)}-${hash.substring(16, 20)}-'
        '${hash.substring(20)}';
  }

  static String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// EPUB 章节条目（标题 + 已生成的 xhtml）
class _ChapterEntry {
  final String title;
  final String xhtml;

  const _ChapterEntry({required this.title, required this.xhtml});
}
