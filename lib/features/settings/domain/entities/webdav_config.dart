/// WebDAV 配置
class WebDavConfig {
  final String url;      // WebDAV 服务器地址
  final String username; // 用户名
  final String password; // 密码

  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
  });

  bool get isConfigured => url.isNotEmpty && username.isNotEmpty;

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }
}
