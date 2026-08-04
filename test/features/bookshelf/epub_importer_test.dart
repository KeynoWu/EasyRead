import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_read/features/bookshelf/data/services/epub_importer.dart';

/// 构建一个最小的合法 EPUB
Uint8List _buildMinimalEpub() {
  final archive = Archive();

  // container.xml
  archive.addFile(ArchiveFile.string(
    'META-INF/container.xml',
    '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
  ));

  // content.opf
  archive.addFile(ArchiveFile.string(
    'OEBPS/content.opf',
    '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试书籍</dc:title>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>
''',
  ));

  // nav.xhtml（EPUB3 导航，提供章节标题）
  archive.addFile(ArchiveFile.string(
    'OEBPS/nav.xhtml',
    '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <body>
    <nav epub:type="toc">
      <ol>
        <li><a href="chapter1.xhtml">第一章 测试标题</a></li>
        <li><a href="chapter2.xhtml">第二章 测试标题</a></li>
      </ol>
    </nav>
  </body>
</html>
''',
  ));

  // chapter1.xhtml
  archive.addFile(ArchiveFile.string(
    'OEBPS/chapter1.xhtml',
    '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <body>
    <h1>第一章</h1>
    <p>这是第一章的内容。</p>
  </body>
</html>
''',
  ));

  // chapter2.xhtml
  archive.addFile(ArchiveFile.string(
    'OEBPS/chapter2.xhtml',
    '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <body>
    <h1>第二章</h1>
    <p>这是第二章的内容。</p>
  </body>
</html>
''',
  ));

  final encoder = ZipEncoder();
  final encoded = encoder.encode(archive);
  return Uint8List.fromList(encoded);
}

void main() {
  group('EpubImporter', () {
    test('should parse minimal epub', () {
      final bytes = _buildMinimalEpub();
      final (title, chapters) = EpubImporter.parseEpub(bytes);
      expect(title, '测试书籍');
      expect(chapters.length, 2);
      expect(chapters[0].$1, '第一章 测试标题');
      expect(chapters[1].$1, '第二章 测试标题');
      expect(chapters[0].$2, contains('这是第一章的内容'));
      expect(chapters[1].$2, contains('这是第二章的内容'));
    });

    test('should preserve paragraph structure in content', () {
      final bytes = _buildMinimalEpub();
      final (_, chapters) = EpubImporter.parseEpub(bytes);
      // 段落之间应有换行分隔（章节标题与正文分离）
      expect(chapters[0].$2, contains('\n'));
      expect(chapters[0].$2, contains('第一章'));
      expect(chapters[0].$2, contains('这是第一章的内容'));
    });

    test('should handle invalid epub', () {
      final (title, chapters) = EpubImporter.parseEpub(Uint8List.fromList([1, 2, 3]));
      expect(chapters, isEmpty);
    });
  });
}
