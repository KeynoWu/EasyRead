import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/book_source.dart';
import '../../domain/repositories/book_source_repository.dart';

/// 可视化书源编辑器
class BookSourceEditPage extends StatefulWidget {
  final BookSource? source;
  final BookSourceRepository repository;

  const BookSourceEditPage({
    super.key,
    this.source,
    required this.repository,
  });

  @override
  State<BookSourceEditPage> createState() => _BookSourceEditPageState();
}

class _BookSourceEditPageState extends State<BookSourceEditPage> {
  late final Map<String, TextEditingController> _controllers;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final s = widget.source;
    _enabled = s?.enabled ?? true;
    _controllers = {
      'name': TextEditingController(text: s?.name ?? ''),
      'group': TextEditingController(text: s?.bookSourceGroup ?? ''),
      'url': TextEditingController(text: s?.bookSourceUrl ?? ''),
      'searchUrl': TextEditingController(text: s?.rules['searchUrl']?.toString() ?? ''),
      'bookList': TextEditingController(text: s?.rules['bookList']?.toString() ?? ''),
      'bookName': TextEditingController(text: s?.rules['bookName']?.toString() ?? ''),
      'bookAuthor': TextEditingController(text: s?.rules['bookAuthor']?.toString() ?? ''),
      'coverUrl': TextEditingController(text: s?.rules['coverUrl']?.toString() ?? ''),
      'bookDetailUrl': TextEditingController(text: s?.rules['bookDetailUrl']?.toString() ?? ''),
      'contentUrl': TextEditingController(text: s?.rules['contentUrl']?.toString() ?? ''),
      'chapterList': TextEditingController(text: s?.rules['chapterList']?.toString() ?? ''),
      'chapterName': TextEditingController(text: s?.rules['chapterName']?.toString() ?? ''),
      'chapterUrl': TextEditingController(text: s?.rules['chapterUrl']?.toString() ?? ''),
      'chapterContent': TextEditingController(text: s?.rules['chapterContent']?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controllers['name']!.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入书源名称')),
      );
      return;
    }

    final rules = <String, dynamic>{
      if (_controllers['searchUrl']!.text.trim().isNotEmpty) 'searchUrl': _controllers['searchUrl']!.text.trim(),
      if (_controllers['bookList']!.text.trim().isNotEmpty) 'bookList': _controllers['bookList']!.text.trim(),
      if (_controllers['bookName']!.text.trim().isNotEmpty) 'bookName': _controllers['bookName']!.text.trim(),
      if (_controllers['bookAuthor']!.text.trim().isNotEmpty) 'bookAuthor': _controllers['bookAuthor']!.text.trim(),
      if (_controllers['coverUrl']!.text.trim().isNotEmpty) 'coverUrl': _controllers['coverUrl']!.text.trim(),
      if (_controllers['bookDetailUrl']!.text.trim().isNotEmpty) 'bookDetailUrl': _controllers['bookDetailUrl']!.text.trim(),
      if (_controllers['contentUrl']!.text.trim().isNotEmpty) 'contentUrl': _controllers['contentUrl']!.text.trim(),
      if (_controllers['chapterList']!.text.trim().isNotEmpty) 'chapterList': _controllers['chapterList']!.text.trim(),
      if (_controllers['chapterName']!.text.trim().isNotEmpty) 'chapterName': _controllers['chapterName']!.text.trim(),
      if (_controllers['chapterUrl']!.text.trim().isNotEmpty) 'chapterUrl': _controllers['chapterUrl']!.text.trim(),
      if (_controllers['chapterContent']!.text.trim().isNotEmpty) 'chapterContent': _controllers['chapterContent']!.text.trim(),
    };

    final source = BookSource(
      id: widget.source?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      bookSourceUrl: _controllers['url']!.text.trim().isEmpty ? null : _controllers['url']!.text.trim(),
      bookSourceGroup: _controllers['group']!.text.trim().isEmpty ? null : _controllers['group']!.text.trim(),
      enabled: _enabled,
      rules: rules,
    );

    await widget.repository.save(source);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source == null ? '新建书源' : '编辑书源'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('基本信息'),
          _buildField('名称', 'name', hint: '书源名称'),
          _buildField('分组', 'group', hint: '如：通用、小说'),
          _buildField('书源地址', 'url', hint: 'https://example.com'),
          SwitchListTile(
            title: const Text('启用'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const Divider(),
          _sectionTitle('搜索规则'),
          _buildField('搜索 URL', 'searchUrl', hint: 'https://example.com/search?keyword={{key}}'),
          _buildField('书籍列表', 'bookList', hint: 'CSS 选择器'),
          _buildField('书名规则', 'bookName', hint: 'h3.title@text'),
          _buildField('作者规则', 'bookAuthor', hint: 'span.author@text'),
          _buildField('封面规则', 'coverUrl', hint: 'img.cover@src'),
          _buildField('详情链接规则', 'bookDetailUrl', hint: 'a.detail@href'),
          const Divider(),
          _sectionTitle('目录规则'),
          _buildField('内容 URL', 'contentUrl', hint: 'https://example.com/chapter/{{id}}.html'),
          _buildField('章节列表', 'chapterList', hint: 'ul.chapter-list > li'),
          _buildField('章节名规则', 'chapterName', hint: 'a@text'),
          _buildField('章节链接规则', 'chapterUrl', hint: 'a@href'),
          const Divider(),
          _sectionTitle('内容规则'),
          _buildField('章节内容', 'chapterContent', hint: 'div#content@html', maxLines: 3),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        title,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildField(String label, String key, {String? hint, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _controllers[key],
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        maxLines: maxLines,
      ),
    );
  }
}
