/// URL 日志脱敏：隐藏 query/fragment 的值，只保留键名与路径，
/// 避免 token/session 等敏感参数进入日志/异常消息。
/// 非 http(s) 或解析失败时原样返回（不掩盖，也不引入二次错误）。
String redactUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return url;
  }
  final base = '${uri.scheme}://${uri.authority}${uri.path}';
  final queryPart = uri.queryParameters.isEmpty
      ? ''
      : uri.queryParameters.keys.map((k) => '$k=***').join('&');
  final suffix = StringBuffer();
  if (queryPart.isNotEmpty) suffix.write('?$queryPart');
  if (uri.hasFragment) suffix.write('#***');
  return '$base$suffix';
}
