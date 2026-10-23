import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Converts declarative XPath rules into the existing, bounded WebKit runtime.
/// No additional browser, interpreter or background polling is introduced.
class KazumiRule {
  static List<String>? indexUrls(String text, String origin) {
    final base = Uri.tryParse(origin);
    if (base == null ||
        base.pathSegments.lastOrNull != 'index.json' ||
        !text.trimLeft().startsWith('[')) {
      return null;
    }
    try {
      final rows = jsonDecode(text);
      if (rows is! List ||
          rows.isEmpty ||
          !rows.every(
            (row) =>
                row is Map &&
                row['name'] is String &&
                row.containsKey('version') &&
                row.containsKey('useNativePlayer'),
          )) {
        return null;
      }
      return rows
          .map((row) {
            final name = row['name'] as String;
            if (!RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_.-]{0,99}$').hasMatch(name)) {
              throw const FormatException('Kazumi 索引包含无效规则名');
            }
            return base.resolve('${Uri.encodeComponent(name)}.json').toString();
          })
          .toSet()
          .toList();
    } on FormatException {
      return null;
    }
  }

  static bool matches(String text) {
    if (!text.trimLeft().startsWith('{')) return false;
    try {
      final value = jsonDecode(text);
      return value is Map &&
          value.containsKey('searchList') &&
          value.containsKey('chapterResult') &&
          value.containsKey('baseURL');
    } on FormatException {
      return false;
    }
  }

  static String convert(String text, {String originUrl = ''}) {
    final rule = Map<String, Object?>.from(jsonDecode(text) as Map);
    final api = int.tryParse('${rule['api'] ?? 1}');
    if (api == null || api < 1 || api > 5) {
      throw const FormatException('暂不支持此 Kazumi 规则 API 版本');
    }
    if (rule['deprecated'] == true) {
      throw const FormatException('此 Kazumi 规则已被维护者标记为停用');
    }
    for (final key in [
      'name',
      'baseURL',
      'searchURL',
      'searchList',
      'searchName',
      'searchResult',
      'chapterRoads',
      'chapterResult',
    ]) {
      final value = rule[key];
      if (value is! String || value.trim().isEmpty || value.length > 8192) {
        throw FormatException('Kazumi 规则缺少有效 $key');
      }
    }
    for (final key in ['baseURL', 'searchURL']) {
      final uri = Uri.tryParse(rule[key] as String);
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw FormatException('Kazumi $key 必须是 http(s) 地址');
      }
    }
    final identity = originUrl.isEmpty ? '${rule['name']}' : originUrl;
    final metadata = {
      'id':
          'kazumi_${sha256.convert(utf8.encode(identity)).toString().substring(0, 24)}',
      'name': rule['name'],
      'version': '${rule['version'] ?? '1'}',
      'category': 'video',
      'mirrors': [rule['baseURL']],
    };
    return '// LumeSource: ${jsonEncode(metadata)}\nconst kazumiRule = ${jsonEncode(rule)};\n$_runtime';
  }

  static const _runtime = r'''
function kazumiHeaders(page) {
  const h = {Referer: kazumiRule.referer || page || kazumiRule.baseURL};
  if (kazumiRule.userAgent) h['User-Agent'] = kazumiRule.userAgent;
  return h;
}
async function kazumiPage(url, script, form) {
  const headers = kazumiHeaders(url);
  const options = {url, script, headers, timeoutMs: 8000};
  if (form != null) {
    options.method = 'POST'; options.body = form;
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  return LumeSource.web.render(options);
}
function kazumiExtract(mode) {
  return 'const rule = ' + JSON.stringify(kazumiRule) + '; const mode = ' + JSON.stringify(mode) + ';' + `
    function nodes(path, root) {
      if (root && path.startsWith('//')) path = '.' + path;
      return LumeWeb.xpath(path, root || document);
    }
    function href(node) {
      if (!node) return '';
      try { const u = new URL(node.getAttribute('href') || '', location.href); return /^https?:$/.test(u.protocol) ? u.href : ''; } catch (_) { return ''; }
    }
    if (mode === 'search') {
      const seen = new Set();
      return nodes(rule.searchList).map(row => {
        const title = nodes(rule.searchName, row)[0];
        const url = href(nodes(rule.searchResult, row)[0]);
        const img = row.querySelector('img');
        let cover = img && (img.getAttribute('data-original') || img.getAttribute('data-src') || img.getAttribute('src'));
        try { cover = cover ? new URL(cover, location.href).href : ''; } catch (_) { cover = ''; }
        return {id: url, title: (title && title.textContent || '').trim(), cover};
      }).filter(item => item.id && item.title && !seen.has(item.id) && seen.add(item.id));
    }
    const chapters = [], seen = new Set();
    let roads = nodes(rule.chapterRoads);
    if (!roads.length) roads = [document];
    roads.forEach((road, index) => {
      for (const link of nodes(rule.chapterResult, road)) {
        const id = href(link), title = (link.textContent || '').trim();
        if (id && title && !seen.has(id)) { seen.add(id); chapters.push({id, title: (roads.length > 1 ? '线路' + (index+1) + ' · ' : '') + title}); }
      }
    });
    // Some rules deliberately use a document-level XPath for episode links.
    if (!chapters.length) for (const link of nodes(rule.chapterResult)) {
      const id = href(link), title = (link.textContent || '').trim();
      if (id && title && !seen.has(id)) { seen.add(id); chapters.push({id, title}); }
    }
    const meta = document.querySelector('meta[property="og:description"],meta[name="description"]');
    const image = document.querySelector('meta[property="og:image"]');
    return {id: location.href, title: document.title, description: meta ? meta.content : '', cover: image ? image.content : '', chapters};
  `;
}
LumeSource = {
  categories: async () => [],
  // Kazumi's contract supplies search, not a home-feed selector.
  list: async p => p.keyword ? LumeSource.search(p) : ({items: [], hasMore: false}),
  search: async p => {
    if ((p.page || 1) > 1) return {items: [], hasMore: false};
    let url = kazumiRule.searchURL.replace(/@keyword/g, encodeURIComponent(p.keyword || ''));
    let form;
    if (kazumiRule.usePost) { const at = url.indexOf('?'); form = at < 0 ? '' : url.slice(at + 1); url = at < 0 ? url : url.slice(0, at); }
    const response = await kazumiPage(url, kazumiExtract('search'), form);
    return {items: response.result || [], hasMore: false};
  },
  detail: async p => (await kazumiPage(p.id, kazumiExtract('detail'))).result,
  chapters: async p => ((await kazumiPage(p.id, kazumiExtract('detail'))).result || {}).chapters || [],
  content: async p => {
    const page = p.chapterId || p.id;
    const response = await kazumiPage(page, 'return null;');
    const media = (response.media || []).find(item => /\.(m3u8|mp4|mpd|flv)([?#]|$)/i.test(item.url));
    if (media && kazumiRule.useNativePlayer !== false) return {kind: 'video', url: media.url, headers: Object.assign({}, media.headers || {}, kazumiHeaders(page))};
    return {kind: 'webplayer', pageUrl: page, headers: kazumiHeaders(page)};
  }
};
''';
}
