import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../js/source_script.dart';

enum SourcePackageKind { javascript, python, module }

/// Runtime markers live with the script, so backup, refresh and restore retain
/// the selected interpreter without a database migration.
class SourcePackage {
  /// Preserve legacy PEP 263 encodings for CPython to decode (GBK etc.).
  static String fromBytes(
    List<int> bytes, {
    String name = '',
    String originUrl = '',
  }) {
    final preview = utf8.decode(bytes, allowMalformed: true);
    final python =
        name.toLowerCase().endsWith('.py') ||
        (Uri.tryParse(originUrl)?.path.toLowerCase().endsWith('.py') ??
            false) ||
        kindOf(preview) == SourcePackageKind.python;
    if (!python) return preview;
    try {
      final script = stripScriptBom(utf8.decode(bytes));
      return prepare(
        '# LumeRuntime: python\n$script',
        name: name,
        originUrl: originUrl,
      );
    } on FormatException {
      return prepare(
        '# LumeRuntime: python\n# LumePythonBytes: ${base64Encode(bytes)}',
        name: name,
        originUrl: originUrl,
      );
    }
  }

  static SourcePackageKind kindOf(String script) {
    if (RegExp(
          r'^\s*#\s*LumeRuntime:\s*python',
          multiLine: true,
        ).hasMatch(script) ||
        RegExp(
          r'^class\s+Spider\s*(?:\(|:)',
          multiLine: true,
        ).hasMatch(script) ||
        RegExp(
          r'^def\s+(?:homeContent|getHomeContent)\s*\(',
          multiLine: true,
        ).hasMatch(script)) {
      return SourcePackageKind.python;
    }
    if (RegExp(
          r'^\s*//\s*LumeRuntime:\s*module',
          multiLine: true,
        ).hasMatch(script) ||
        RegExp(
          r'^\s*export\s+(default|const|let|var|function|async|class|\{)',
          multiLine: true,
        ).hasMatch(script) ||
        script.contains('module.exports')) {
      return SourcePackageKind.module;
    }
    return SourcePackageKind.javascript;
  }

  static bool looksLikeScript(String text) =>
      kindOf(text) != SourcePackageKind.javascript;

  /// Give scripts without Lume metadata a stable identity before overwrite
  /// confirmation. URL/file identity survives edits; pasted scripts use content.
  static String prepare(String raw, {String name = '', String originUrl = ''}) {
    final script = stripScriptBom(raw);
    final kind = kindOf(script);
    if (kind == SourcePackageKind.javascript) return raw;
    final prefix = kind == SourcePackageKind.python ? '#' : '//';
    final marker = '$prefix LumeRuntime: ${kind.name}';
    final metadata = SourceMetadata.parseHeader(script);
    if (metadata != null) {
      return script.contains(marker) ? script : '$marker\n$script';
    }
    var label = name.trim();
    if (label.isEmpty && originUrl.isNotEmpty) {
      label = Uri.tryParse(originUrl)?.pathSegments.lastOrNull ?? '';
    }
    label = label.replaceFirst(RegExp(r'\.(py|mjs|cjs|js)$'), '');
    if (label.isEmpty) {
      label = kind == SourcePackageKind.python ? 'Python 源' : '模块源';
    }
    final identity = originUrl.isNotEmpty
        ? originUrl
        : name.isNotEmpty
        ? name
        : script;
    final id =
        '${kind.name}_${sha256.convert(utf8.encode(identity)).toString().substring(0, 24)}';
    return '$marker\n$prefix LumeSource: ${jsonEncode({'id': id, 'name': label, 'version': '1', 'category': 'video'})}\n$script';
  }
}
