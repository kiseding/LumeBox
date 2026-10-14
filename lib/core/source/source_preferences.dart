import 'dart:convert';

import '../reading/reading_library.dart';
import '../session/section.dart';

/// Per-section display and routing preferences, kept separate from downloaded scripts.
class SourcePreferences {
  const SourcePreferences({
    this.pinned = false,
    this.iconUrl = '',
    this.originalOrigin = '',
    this.customOrigin = '',
    this.newestFirst = false,
  });
  final bool pinned, newestFirst;
  final String iconUrl, originalOrigin, customOrigin;
  static String _key(String id) => 'source.preferences.$id';
  static SourcePreferences read(Section section, String id) {
    try {
      final raw = ReadingLibrary.find(section)?.setting(_key(id));
      final map = raw == null ? null : jsonDecode(raw);
      if (map is! Map) return const SourcePreferences();
      return SourcePreferences(
        pinned: map['pinned'] == true,
        iconUrl: '${map['iconUrl'] ?? ''}',
        originalOrigin: '${map['originalOrigin'] ?? ''}',
        customOrigin: '${map['customOrigin'] ?? ''}',
        newestFirst: map['newestFirst'] == true,
      );
    } catch (_) {
      return const SourcePreferences();
    }
  }

  Future<void> save(Section section, String id) async {
    final library = await ReadingLibrary.open(section);
    library.setSetting(
      _key(id),
      jsonEncode({
        'pinned': pinned,
        'iconUrl': iconUrl,
        'originalOrigin': originalOrigin,
        'customOrigin': customOrigin,
        'newestFirst': newestFirst,
      }),
    );
  }

  SourcePreferences copyWith({
    bool? pinned,
    bool? newestFirst,
    String? iconUrl,
    String? originalOrigin,
    String? customOrigin,
  }) => SourcePreferences(
    pinned: pinned ?? this.pinned,
    newestFirst: newestFirst ?? this.newestFirst,
    iconUrl: iconUrl ?? this.iconUrl,
    originalOrigin: originalOrigin ?? this.originalOrigin,
    customOrigin: customOrigin ?? this.customOrigin,
  );
  String rewrite(String url) {
    final from = Uri.tryParse(originalOrigin),
        to = Uri.tryParse(customOrigin),
        uri = Uri.tryParse(url);
    if (from == null ||
        to == null ||
        uri == null ||
        !uri.hasAuthority ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        !validOrigin(originalOrigin) ||
        !validOrigin(customOrigin) ||
        uri.origin != from.origin) {
      return url;
    }
    return uri
        .replace(scheme: to.scheme, host: to.host, port: to.port, userInfo: '')
        .toString();
  }

  static bool validOrigin(String text) {
    final u = Uri.tryParse(text.trim());
    return u != null &&
        (u.scheme == 'https' || u.scheme == 'http') &&
        u.host.isNotEmpty &&
        u.userInfo.isEmpty &&
        (u.path.isEmpty || u.path == '/') &&
        !u.hasQuery &&
        !u.hasFragment;
  }
}
