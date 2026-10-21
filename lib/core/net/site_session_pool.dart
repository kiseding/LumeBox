import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../reading/reading.dart';
import '../session/section.dart';
import 'waf.dart';

/// One application session, scoped by cookie domain/path and exact-host UA.
/// Secrets remain in WebKit's cookie store; only UA preferences are persisted here.
class SiteSessionPool {
  static final shared = SiteSessionPool();
  static const channel = MethodChannel('lumebox/source_web');
  final Map<String, String> userAgents = {};
  final Map<String, String> _verifiedAgents = {};
  final Set<String> _changedAgents = {};
  String? userAgentFor(String url) =>
      userAgents[Uri.parse(url).host] ?? _verifiedAgents[Uri.parse(url).host];
  final Map<String, String> _referers = {};
  final Map<String, String> _sourcePages = {};
  final Map<String, Map<String, Object?>> _cookies = {};
  bool inspectable = false;
  ReadingLibrary? _library;

  Future<void> boot() async {
    _library = await ReadingLibrary.open(Section.video);
    final raw = _library!.setting('site.network.options');
    if (raw == null) return;
    final value = jsonDecode(raw) as Map;
    inspectable = value['inspectable'] == true;
    userAgents.addAll(
      (value['userAgents'] as Map? ?? {}).map((k, v) => MapEntry('$k', '$v')),
    );
  }

  Future<void> save() async {
    _library = await ReadingLibrary.open(Section.video);
    _library!.setSetting(
      'site.network.options',
      jsonEncode({'inspectable': inspectable, 'userAgents': userAgents}),
    );
    try {
      await channel.invokeMethod<void>('configure', {
        'inspectable': inspectable,
        'clearVerificationHosts': _changedAgents.toList(),
      });
      _changedAgents.clear();
    } on MissingPluginException {
      /* Non-iOS. */
    }
  }

  void setUserAgent(String url, String value) {
    final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效站点域名');
    }
    if (value.length > 2048 || value.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('UA 无效');
    }
    _changedAgents.add(uri.host);
    _verifiedAgents.remove(uri.host);
    _cookies.removeWhere(
      (_, v) =>
          ['cf_clearance', '__cf_bm'].contains(v['name']) &&
          (uri.host == '${v['domain']}'.replaceFirst(RegExp(r'^\.'), '') ||
              uri.host.endsWith('${v['domain']}')),
    );
    if (userAgents.length >= 128 && !userAgents.containsKey(uri.host))
      throw const FormatException('站点 UA 最多保存 128 项');
    if (value.trim().isEmpty) {
      userAgents.remove(uri.host);
    } else {
      userAgents[uri.host] = value.trim();
    }
  }

  String? pageForSource(String source) => _sourcePages[source];
  void rememberSourcePage(String source, String url) {
    rememberPage(url);
    _sourcePages[source] = url;
    while (_sourcePages.length > 128) {
      _sourcePages.remove(_sourcePages.keys.first);
    }
  }

  void rememberPage(String url, {String? userAgent}) {
    final uri = Uri.tryParse(url);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) return;
    _referers[uri.host] = uri.removeFragment().replace(userInfo: '').toString();
    if (userAgent != null && userAgent.isNotEmpty)
      _verifiedAgents[uri.host] = userAgent;
    while (_verifiedAgents.length > 128) {
      _verifiedAgents.remove(_verifiedAgents.keys.first);
    }
    while (_referers.length > 128) {
      _referers.remove(_referers.keys.first);
    }
  }

  void importCookies(List<Object?> values) {
    for (final value in values) {
      if (value is! Map) continue;
      final entry = value.map((k, v) => MapEntry('$k', v));
      final key = '${entry['domain']}|${entry['path']}|${entry['name']}';
      _cookies[key] = entry;
    }
    _cookies.removeWhere(
      (_, v) =>
          v['expires'] is num &&
          (v['expires'] as num) * 1000 <= DateTime.now().millisecondsSinceEpoch,
    );
    while (_cookies.length > 512) {
      _cookies.remove(_cookies.keys.first);
    }
  }

  void absorb(String url, Map<String, String> headers) {
    final uri = Uri.parse(url);
    final raw = headers.entries
        .where((e) => e.key.toLowerCase() == 'set-cookie')
        .firstOrNull
        ?.value;
    if (raw == null) return;
    // A comma inside Expires is not a cookie separator.
    for (final part in raw.split(RegExp(r',(?=\s*[^;,=\s]+=)'))) {
      try {
        final c = Cookie.fromSetCookieValue(part);
        final domain = c.domain?.toLowerCase() ?? uri.host;
        final bare = domain.replaceFirst(RegExp(r'^\.'), '');
        if (uri.host != bare && !uri.host.endsWith('.$bare')) continue;
        final defaultPath = uri.path.contains('/')
            ? uri.path.substring(0, uri.path.lastIndexOf('/') + 1)
            : '/';
        // WebKit is authoritative on iOS. Off-device fallback keeps server
        // cookies host-only instead of implementing an incomplete public-suffix list.
        importCookies([
          {
            'name': c.name,
            'value': c.value,
            'domain': uri.host,
            'path': c.path ?? defaultPath,
            'secure': c.secure,
            'expires': c.maxAge != null
                ? DateTime.now().millisecondsSinceEpoch / 1000 + c.maxAge!
                : c.expires?.millisecondsSinceEpoch == null
                ? null
                : c.expires!.millisecondsSinceEpoch / 1000,
          },
        ]);
      } on FormatException {
        /* Invalid server cookie is ignored. */
      }
    }
  }

  Map<String, String> headersFor(
    String url,
    Map<String, String> original, {
    String? referer,
  }) {
    final uri = Uri.parse(url);
    final headers = <String, String>{
      for (final e in original.entries)
        switch (e.key.toLowerCase()) {
          'user-agent' => 'User-Agent',
          'cookie' => 'Cookie',
          'referer' => 'Referer',
          _ => e.key,
        }: e.value,
    };
    final ua = userAgentFor(url);
    if (ua != null) headers['User-Agent'] = ua;
    final selected = webViewCookiesForUrl(_cookies.values.toList(), url);
    final cookie = mergeCookieHeader(
      existing: headers['Cookie'],
      wafCookies: selected.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
    if (cookie != null && cookie.isNotEmpty) headers['Cookie'] = cookie;
    final page = referer ?? _referers[uri.host];
    if (page != null && !headers.containsKey('Referer')) {
      final parsed = Uri.tryParse(page);
      if (parsed != null &&
          ['http', 'https'].contains(parsed.scheme) &&
          !(parsed.scheme == 'https' && uri.scheme == 'http')) {
        headers['Referer'] = parsed
            .removeFragment()
            .replace(userInfo: '')
            .toString();
      }
    }
    return headers;
  }

  Future<Map<String, String>> synchronize(
    String url,
    Map<String, String> headers, {
    bool forceCookies = false,
  }) async {
    if (!Platform.isIOS) {
      final merged = headersFor(url, headers);
      if (forceCookies && headers.containsKey('Cookie'))
        merged['Cookie'] = headers['Cookie']!;
      return merged;
    }
    final result = await channel
        .invokeMapMethod<String, dynamic>('session', {
          'url': url,
          'headers': headers,
          'forceCookies': forceCookies,
          'inspectable': inspectable,
        })
        .timeout(const Duration(seconds: 3));
    final host = Uri.parse(url).host;
    _cookies.removeWhere((_, v) {
      final d = '${v['domain']}'.replaceFirst(RegExp(r'^\.'), '');
      return host == d ||
          ('${v['domain']}'.startsWith('.') && host.endsWith('.$d'));
    });
    importCookies((result?['cookies'] as List?)?.cast<Object?>() ?? []);
    final cleaned = Map<String, String>.of(headers)
      ..removeWhere((k, _) => k.toLowerCase() == 'cookie');
    return headersFor(url, cleaned);
  }

  void forgetHosts(Set<String> hosts, {Set<String> protectedHosts = const {}}) {
    bool removable(String host) =>
        hosts.contains(host) && !protectedHosts.contains(host);
    _cookies.removeWhere((_, v) {
      final d = '${v['domain']}'.replaceFirst(RegExp(r'^\.'), '');
      return hosts.any((h) => h == d || h.endsWith('.$d')) &&
          !protectedHosts.any((h) => h == d || h.endsWith('.$d'));
    });
    _referers.removeWhere((host, _) => removable(host));
    _verifiedAgents.removeWhere((host, _) => removable(host));
    _sourcePages.removeWhere((_, url) => removable(Uri.parse(url).host));
  }

  void clear() {
    _cookies.clear();
    _referers.clear();
    _sourcePages.clear();
    userAgents.clear();
    _verifiedAgents.clear();
    _changedAgents.clear();
  }
}
