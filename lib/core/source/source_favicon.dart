import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/lume_http.dart';
import '../net/source_request_log.dart';
import '../net/waf.dart';
import '../session/section.dart';
import '../util/lume_log.dart';

/// 源图标解析：把「这个源没有图标」这件事在应用层补上。
///
/// 为什么不在控件里直接 `Image.network('${origin}/favicon.ico')`：
/// 1. **图标常常不在 /favicon.ico**：真机里一片首字母占位的根因就是这个——
///    实测多个源在 /favicon.ico 上回的是 HTML（站点的 404 页）或 404，
///    真正的图标写在首页的 `<link rel="icon">` / `apple-touch-icon` 里；
/// 2. **裸请求会被挡**：`Image.network` 不带 UA / Cookie，Cloudflare 站直接 403，
///    而该源的会话（`cf_clearance` 与验证时的 UA）就在库里，白放着不用；
/// 3. **列表会反复打同一个站**：源列表一次渲染几十项，每项一个请求会重复拉同一个
///    域名，必须去重 + 缓存。
///
/// 因此这里的顺序是：候选地址（源声明的 icon → /favicon.ico → /favicon.png →
/// /apple-touch-icon.png）→ 全都不行就抓首页解析 `<link rel=icon>` → 逐个取字节
/// （经全局网络队列，带该源会话）→ 校验**确实是图片**（不认 SVG：Flutter 画不了）
/// → 缓存结果（含「取不到」）。取不到就老实回退首字母，绝不假装有图标。
class SourceFavicon {
  SourceFavicon({LumeHttp? http, this.maxEntries = 96, this.fetchHtmlHomepage = true})
    : _http = http ?? LumeHttp(source: '源图标');

  /// 应用级单例：列表页与设置页共用一份缓存，同一个源只请求一次。
  static final SourceFavicon instance = SourceFavicon();

  /// 单张图标的读取上限（图标不该超过这个量级）。
  static const int maxBytes = 256 * 1024;

  /// 单次请求超时：图标是锦上添花，不该拖慢列表。取 5 秒（队列内部还有重试，
  /// 真连不上的站点最多也就耗一个 5 秒 × 重试次数，不会长时间占着后台）。
  static const Duration timeout = Duration(seconds: 5);

  final LumeHttp _http;

  /// 缓存条目上限（按源去重，96 个源足够覆盖当前全部源）。
  final int maxEntries;

  /// 候选全挂时要不要再抓一次首页解析图标地址。
  final bool fetchHtmlHomepage;

  final Map<String, Uint8List?> _cache = <String, Uint8List?>{};
  final Map<String, Future<Uint8List?>> _inflight = <String, Future<Uint8List?>>{};

  /// 取图标字节；拿不到返回 null（调用方回退首字母占位）。
  ///
  /// [origin] 是站点根（`https://a.com`）；[explicit] 是源自己声明的图标地址，
  /// 优先级最高。同一个 (origin, explicit) 组合只真正请求一次，结果（含失败）
  /// 都缓存住——列表滚动、切页签都不会重新打一遍站点。
  Future<Uint8List?> load({
    required String origin,
    List<String> explicit = const <String>[],
    Section? section,
    String? sourceId,
  }) {
    final key = _key(origin, explicit);
    if (key.isEmpty) return Future<Uint8List?>.value();
    if (_cache.containsKey(key)) {
      return Future<Uint8List?>.value(_cache[key]);
    }
    final running = _inflight[key];
    if (running != null) return running;
    final task = _resolve(
      origin: origin,
      explicit: explicit,
      section: section,
      sourceId: sourceId,
    ).then((bytes) {
      _remember(key, bytes);
      return bytes;
    }).whenComplete(() {
      // 用块体而不是箭头：箭头写法会把 `Map.remove` 的返回值（就是这条 future
      // 本身）当成「还要等它」——自我等待，永远不完成。
      _inflight.remove(key);
    });
    _inflight[key] = task;
    return task;
  }

  /// 测试用：清掉缓存与在飞表。
  @visibleForTesting
  void clearCache() {
    _cache.clear();
    _inflight.clear();
  }

  void _remember(String key, Uint8List? bytes) {
    if (_cache.length >= maxEntries && !_cache.containsKey(key)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = bytes;
  }

  static String _key(String origin, List<String> explicit) {
    final icons = explicit
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final site = origin.trim();
    if (site.isEmpty && icons.isEmpty) return '';
    return '$site|${icons.join(',')}';
  }

  Future<Uint8List?> _resolve({
    required String origin,
    required List<String> explicit,
    Section? section,
    String? sourceId,
  }) async {
    var reachable = false;
    for (final url in _candidates(origin, explicit)) {
      final attempt = await _fetch(
        url,
        section: section,
        sourceId: sourceId,
        referer: origin.isEmpty ? '' : '$origin/',
      );
      if (attempt.bytes != null) return attempt.bytes;
      if (attempt.reachable) reachable = true;
    }
    // 一个候选都没能连上（DNS 不通 / 被墙）：再去抓首页只是白等一轮，
    // 直接认「这个源没有图标」——首字母占位立刻出来，列表不跟着拖。
    if (!fetchHtmlHomepage || origin.isEmpty || !reachable) return null;
    final home = await _fetchText(
      '$origin/',
      section: section,
      sourceId: sourceId,
    );
    if (home == null) return null;
    for (final url in iconLinksFromHtml(home, origin)) {
      final attempt = await _fetch(
        url,
        section: section,
        sourceId: sourceId,
        referer: '$origin/',
      );
      if (attempt.bytes != null) return attempt.bytes;
    }
    return null;
  }

  /// 候选地址：源声明的图标在前，站点约定名在后（都不带 SVG——Flutter 画不出来）。
  static List<String> _candidates(String origin, List<String> explicit) {
    final out = <String>[];
    for (final url in explicit) {
      final text = url.trim();
      if (_isUsableUrl(text)) out.add(text);
    }
    final site = _originOf(origin);
    if (site.isNotEmpty) {
      for (final path in const <String>[
        '/favicon.ico',
        '/favicon.png',
        '/apple-touch-icon.png',
      ]) {
        out.add('$site$path');
      }
    }
    return out.toSet().toList(growable: false);
  }

  /// 站点根：`https://a.com/x` → `https://a.com`（带端口也照留）。
  static String _originOf(String siteUrl) {
    final uri = Uri.tryParse(siteUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    if (!const <String>{'http', 'https'}.contains(uri.scheme)) return '';
    return uri.hasPort ? '${uri.scheme}://${uri.host}:${uri.port}' : '${uri.scheme}://${uri.host}';
  }

  static bool _isUsableUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    if (!const <String>{'http', 'https'}.contains(uri.scheme)) return false;
    return !uri.path.toLowerCase().endsWith('.svg');
  }

  /// 从首页 HTML 里挑图标地址（纯函数，单独可验证）。
  ///
  /// 规则照着浏览器那一套来：`apple-touch-icon` 优先（几乎都是方正的 PNG），
  /// 其余 `rel=icon` 按 `sizes` 从大到小排；`.svg` 直接跳过（Flutter 解不了）。
  @visibleForTesting
  static List<String> iconLinksFromHtml(String html, String origin) {
    final site = _originOf(origin);
    final found = <({String url, int size, int apple})>[];
    final pattern = RegExp(r'<link\b[^>]*>', caseSensitive: false);
    for (final match in pattern.allMatches(html)) {
      final tag = match.group(0)!;
      final rel = _attribute(tag, 'rel').toLowerCase();
      if (!rel.contains('icon')) continue;
      final href = _attribute(tag, 'href');
      if (href.isEmpty) continue;
      final url = _absolute(href, site);
      if (!_isUsableUrl(url)) continue;
      final sizes = _attribute(tag, 'sizes');
      final side = int.tryParse(RegExp(r'(\d+)').firstMatch(sizes)?.group(1) ?? '') ?? 0;
      found.add((url: url, size: side, apple: rel.contains('apple') ? 1 : 0));
    }
    found.sort((a, b) {
      if (a.apple != b.apple) return b.apple - a.apple;
      return b.size - a.size;
    });
    final out = <String>[];
    for (final item in found) {
      if (!out.contains(item.url)) out.add(item.url);
    }
    return out;
  }

  static String _attribute(String tag, String name) {
    final match = RegExp(
      '$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
      caseSensitive: false,
    ).firstMatch(tag);
    if (match == null) return '';
    return (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim();
  }

  static String _absolute(String href, String site) {
    final text = href.trim();
    if (text.startsWith('//')) return site.isEmpty ? '' : 'https:$text';
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(text)) return text;
    if (site.isEmpty) return '';
    return text.startsWith('/') ? '$site$text' : '$site/$text';
  }

  /// 取一张图；状态码不是 200、内容不是图片（或解不了的 SVG）都当作「没有」。
  ///
  /// 返回值带上「这条请求有没有真的到过服务器」：全都没到过就不必再抓首页了。
  Future<({Uint8List? bytes, bool reachable})> _fetch(
    String url, {
    Section? section,
    String? sourceId,
    String referer = '',
  }) async {
    try {
      final response = await _http.send(
        url: url,
        headers: _headers(url, section: section, sourceId: sourceId, referer: referer),
        timeout: timeout,
        maxBytes: maxBytes,
      );
      if (response.statusCode != 200) {
        return (bytes: null, reachable: true);
      }
      return (
        bytes: _asImage(response.body, response.headers['content-type']),
        reachable: true,
      );
    } on Object catch (error) {
      // 图标取不到是常态（站点没有 / 被墙 / 被 WAF 挡），不值得打扰用户；
      // 但排查「某个源为什么没图标」时日志里要能看到试过哪个地址。
      LumeLog.info('[源图标] 取不到 $url：$error');
      return (bytes: null, reachable: false);
    }
  }

  /// 取首页 HTML（只为解析图标地址，读满上限即断）。
  Future<String?> _fetchText(
    String url, {
    Section? section,
    String? sourceId,
  }) async {
    try {
      final response = await _http.send(
        url: url,
        headers: _headers(url, section: section, sourceId: sourceId, referer: url),
        timeout: timeout,
        maxBytes: maxBytes,
      );
      if (response.statusCode != 200) return null;
      return response.text;
    } on Object catch (error) {
      LumeLog.info('[源图标] 首页解析失败 $url：$error');
      return null;
    }
  }

  /// 请求头：源自己域名上的请求带上该源**验证过的会话**（Cookie + UA）。
  ///
  /// 只发给源站自己的域名（[SourceRequestLog.ownsHost] 记的地址），其他域名一枚
  /// 都不带——把源站凭据泄漏给第三方域名是更严重的问题。
  Map<String, String> _headers(
    String url, {
    Section? section,
    String? sourceId,
    String referer = '',
  }) {
    final headers = <String, String>{'Accept': 'image/*,*/*;q=0.8'};
    if (referer.isNotEmpty) headers['Referer'] = referer;
    if (section == null || sourceId == null) return headers;
    if (!SourceRequestLog.ownsHost(sourceId, url)) return headers;
    final cookies = WafSessions.cookiesFor(section, sourceId)?.trim() ?? '';
    if (cookies.isNotEmpty) headers['Cookie'] = cookies;
    final ua = WafSessions.userAgentFor(section, sourceId)?.trim() ?? '';
    if (ua.isNotEmpty) headers['User-Agent'] = ua;
    return headers;
  }

  /// 内容确实是能画的图片才算数：先看 content-type，再看字节魔数（有些站把
  /// PNG 当 `image/x-icon` 发，也有站把 HTML 404 页当图标发）。
  static Uint8List? _asImage(Uint8List bytes, String? contentType) {
    if (bytes.isEmpty) return null;
    final type = (contentType ?? '').toLowerCase();
    if (type.contains('svg')) return null;
    if (type.startsWith('text/') || type.contains('html') || type.contains('json')) {
      return null;
    }
    return _looksLikeImage(bytes) ? bytes : null;
  }

  /// 图片魔数：PNG / JPEG / GIF / BMP / WEBP / ICO。
  static bool _looksLikeImage(Uint8List bytes) {
    if (bytes.length < 4) return false;
    const png = <int>[0x89, 0x50, 0x4E, 0x47];
    const jpeg = <int>[0xFF, 0xD8, 0xFF];
    const gif = <int>[0x47, 0x49, 0x46];
    const bmp = <int>[0x42, 0x4D];
    const ico = <int>[0x00, 0x00, 0x01, 0x00];
    for (final magic in const <List<int>>[png, jpeg, gif, bmp, ico]) {
      if (_startsWith(bytes, magic)) return true;
    }
    // WEBP：RIFF....WEBP
    if (bytes.length >= 12 &&
        _startsWith(bytes, const <int>[0x52, 0x49, 0x46, 0x46]) &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  static bool _startsWith(Uint8List bytes, List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }
}
