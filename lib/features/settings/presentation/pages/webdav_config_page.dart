import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/webdav_config.dart';
import '../../domain/usecases/webdav_sync.dart';

class WebDavConfigPage extends StatefulWidget {
  const WebDavConfigPage({super.key});

  @override
  State<WebDavConfigPage> createState() => _WebDavConfigPageState();
}

class _WebDavConfigPageState extends State<WebDavConfigPage> {
  final _sync = WebDavSync();
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final config = _sync.getConfig();
    _urlController = TextEditingController(text: config.url);
    _usernameController = TextEditingController(text: config.username);
    _passwordController = TextEditingController(text: config.password);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final config = WebDavConfig(
      url: _urlController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text.trim(),
    );
    await _sync.saveConfig(config);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('配置已保存')),
    );
  }

  Future<void> _test() async {
    final result = await _sync.testConnection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result ?? '连接成功')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV 配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '配置 WebDAV 服务器后，可将书架、书源数据备份到云端，支持跨设备同步。',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://dav.example.com/easyread/',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : _test,
                  child: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
