import 'dart:convert';

/// HTML is kept in the settings backup, rather than a transient Files URL.
class WebHomeImport {
  WebHomeImport._();
  static const maxBytes = 2 * 1024 * 1024;

  static String decode(List<int> bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('HTML 文件不能超过 2 MB');
    }
    final text = utf8.decode(bytes).replaceFirst('\uFEFF', '');
    if (!RegExp(
      r'<(?:!doctype\s+html|html|head|body)(?:\s|>)',
      caseSensitive: false,
    ).hasMatch(text)) {
      throw const FormatException('请选择完整的 UTF-8 HTML 网页文件');
    }
    return text;
  }

  static String name(String html, String filename) {
    final title =
        RegExp(r'<title\b[^>]*>([\s\S]*?)</title>', caseSensitive: false)
            .firstMatch(html)
            ?.group(1)
            ?.replaceAll(RegExp(r'<[^>]*>'), '')
            .trim()
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>') ??
        '';
    return title.isNotEmpty
        ? title
        : filename.replaceFirst(RegExp(r'\.html?$', caseSensitive: false), '');
  }
}
