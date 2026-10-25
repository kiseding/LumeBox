import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

import '../search/search_settings.dart';
import '../net/lume_net.dart';

enum TmdbPosterStyle { fixed, random, carousel }

enum TmdbImageKind {
  backdrop('背景图', ['original', 'w1280', 'w780'], 'w1280'),
  logo('Logo', ['original', 'w500'], 'w500'),
  poster('海报', ['original', 'w500', 'w342'], 'w500'),
  profile('演员头像', ['original', 'w632', 'w185'], 'w185'),
  video('视频封面', ['original', 'w500', 'w300'], 'w300');

  const TmdbImageKind(this.label, this.sizes, this.defaultSize);
  final String label;
  final List<String> sizes;
  final String defaultSize;
}

class TmdbSettings extends ChangeNotifier {
  TmdbSettings();
  static final instance = TmdbSettings();
  bool enabled = false;
  TmdbPosterStyle posterStyle = TmdbPosterStyle.fixed;
  String apiKey = '', apiProxy = '', imageProxy = '';
  final Map<TmdbImageKind, String> _imageSizes = {};
  String imageSize(TmdbImageKind kind) => _imageSizes[kind] ?? kind.defaultSize;
  void setImageSize(TmdbImageKind kind, String size) {
    if (!kind.sizes.contains(size)) throw ArgumentError.value(size, 'size');
    _imageSizes[kind] = size;
  }

  int revision = 0;
  File? _file;
  Future<void> _writes = Future.value();
  Future<void> boot() async {
    _imageSizes.clear();
    try {
      _file = File(
        '${(await getApplicationSupportDirectory()).path}/tmdb_settings.json',
      );
      if (await _file!.exists()) {
        final data =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        for (final kind in TmdbImageKind.values) {
          final value = (data['imageSizes'] as Map?)?[kind.name];
          _imageSizes[kind] = kind.sizes.contains(value)
              ? value as String
              : kind.defaultSize;
        }
        enabled = data['enabled'] == true;
        apiKey = data['apiKey'] as String? ?? '';
        apiProxy = data['apiProxy'] as String? ?? '';
        imageProxy = data['imageProxy'] as String? ?? '';
        posterStyle =
            TmdbPosterStyle.values
                .where((e) => e.name == data['posterStyle'])
                .firstOrNull ??
            TmdbPosterStyle.fixed;
      }
    } catch (_) {
      enabled = false;
    }
  }

  Future<void> save() async {
    revision++;
    notifyListeners();
    final snapshot = jsonEncode({
      'enabled': enabled,
      'apiKey': apiKey,
      'apiProxy': apiProxy,
      'imageProxy': imageProxy,
      'posterStyle': posterStyle.name,
      'imageSizes': {
        for (final kind in TmdbImageKind.values) kind.name: imageSize(kind),
      },
    });
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final file = _file;
      if (file == null) return;
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
    });
    await _writes;
  }

  final Map<String, dynamic> _cache = {};
  bool _cacheLoaded = false;
  Future<void> _cacheWrites = Future.value();
  String cacheKey(String title) => jsonEncode([
    'recommendations-v3',
    apiProxy.trim(),
    imageProxy.trim(),
    TmdbClient.normalized(title),
    for (final kind in TmdbImageKind.values) imageSize(kind),
  ]);
  Future<TmdbMetadata?> cached(String key) async {
    if (!_cacheLoaded) {
      _cacheLoaded = true;
      try {
        final file = _file;
        if (file != null) {
          final cache = File('${file.parent.path}/tmdb_metadata.json');
          if (await cache.exists()) {
            _cache.addAll(
              jsonDecode(await cache.readAsString()) as Map<String, dynamic>,
            );
          }
        }
      } catch (_) {
        /* Damaged cache must not affect source details. */
      }
    }
    final value = _cache[key];
    return value is Map<String, dynamic> ? TmdbMetadata.fromJson(value) : null;
  }

  Future<void> cache(String key, TmdbMetadata? value) async {
    await cached(key);
    if (value == null) {
      _cache.remove(key);
    } else {
      _cache[key] = value.toJson();
    }
    final snapshot = jsonEncode(_cache);
    _cacheWrites = _cacheWrites.catchError((Object _) {}).then((_) async {
      final file = _file;
      if (file == null) return;
      final target = File('${file.parent.path}/tmdb_metadata.json');
      final temp = File('${target.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(target.path);
    });
    try {
      await _cacheWrites;
    } catch (_) {
      /* Cache writes are best effort. */
    }
  }

  Future<void> flush() async {
    await _writes;
    await _cacheWrites;
  }

  Future<void> disconnect() {
    enabled = false;
    apiKey = '';
    apiProxy = '';
    imageProxy = '';
    return save();
  }

  bool get configured => enabled && apiKey.trim().isNotEmpty;
  String get credential => apiKey.trim().replaceFirst(
    RegExp(r'^Bearer\s+', caseSensitive: false),
    '',
  );
  bool get usesBearer =>
      apiKey.trim().toLowerCase().startsWith('bearer ') ||
      (credential.startsWith('eyJ') && credential.split('.').length == 3);
  static Uri address(String raw, String fallback) {
    var value = raw.trim();
    if (value.isEmpty) value = fallback;
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效的 HTTP(S) 地址');
    }
    return uri;
  }

  Uri apiUri(
    String endpoint, {
    Uri? base,
    Map<String, String> query = const {},
  }) {
    final root = base ?? address(apiProxy, 'https://api.themoviedb.org');
    final prefix = root.path.replaceAll(RegExp(r'/+$'), '');
    return root.replace(
      path: '$prefix${prefix.endsWith('/3') ? '' : '/3'}/$endpoint',
      queryParameters: {
        ...root.queryParameters,
        ...query,
        if (!usesBearer) 'api_key': credential,
      },
    );
  }

  String imageUrl(String path, {TmdbImageKind kind = TmdbImageKind.poster}) {
    final base = address(imageProxy, 'https://image.tmdb.org/t/p/');
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return base
        .replace(
          path:
              '$prefix/${imageSize(kind)}/${path.replaceFirst(RegExp(r'^/+'), '')}',
        )
        .toString();
  }
}

class TmdbRecommendation {
  const TmdbRecommendation({required this.title, required this.poster});
  final String title, poster;
  Map<String, dynamic> toJson() => {'title': title, 'poster': poster};
  factory TmdbRecommendation.fromJson(Map<String, dynamic> data) =>
      TmdbRecommendation(
        title: data['title'] as String? ?? '',
        poster: data['poster'] as String? ?? '',
      );
}

class TmdbMetadata {
  const TmdbMetadata({
    required this.overview,
    required this.posters,
    this.backdrops = const [],
    this.logos = const [],
    this.profiles = const [],
    this.videoCovers = const [],
    this.cast = const [],
    this.recommendations = const [],
    this.rating = 0,
    this.voteCount = 0,
  });
  final String overview;
  final List<String> posters, backdrops, cast, logos, profiles, videoCovers;
  final List<TmdbRecommendation> recommendations;
  final double rating;
  final int voteCount;
  Map<String, dynamic> toJson() => {
    'overview': overview,
    'posters': posters,
    'backdrops': backdrops,
    'logos': logos,
    'profiles': profiles,
    'videoCovers': videoCovers,
    'cast': cast,
    'recommendations': recommendations.map((item) => item.toJson()).toList(),
    'rating': rating,
    'voteCount': voteCount,
  };
  factory TmdbMetadata.fromJson(Map<String, dynamic> data) => TmdbMetadata(
    recommendations: (data['recommendations'] as List? ?? [])
        .whereType<Map>()
        .map(
          (row) => TmdbRecommendation.fromJson(Map<String, dynamic>.from(row)),
        )
        .where((item) => item.title.trim().isNotEmpty)
        .toList(),
    overview: data['overview'] as String? ?? '',
    posters: (data['posters'] as List? ?? []).whereType<String>().toList(),
    backdrops: (data['backdrops'] as List? ?? []).whereType<String>().toList(),
    cast: (data['cast'] as List? ?? []).whereType<String>().toList(),
    logos: (data['logos'] as List? ?? []).whereType<String>().toList(),
    profiles: (data['profiles'] as List? ?? []).whereType<String>().toList(),
    videoCovers: (data['videoCovers'] as List? ?? [])
        .whereType<String>()
        .toList(),
    rating: (data['rating'] as num?)?.toDouble() ?? 0,
    voteCount: (data['voteCount'] as num?)?.toInt() ?? 0,
  );
}

class TmdbClient {
  TmdbClient(this.settings, {http.Client? client}) : _injected = client {
    settings.addListener(_changed);
  }
  final TmdbSettings settings;
  final http.Client? _injected;
  final _active = <http.Client>{};
  void _changed() {
    for (final client in _active.toList()) {
      client.close();
    }
    _active.clear();
  }

  void dispose() {
    settings.removeListener(_changed);
    _changed();
  }

  Future<http.Response> _get(Uri uri, int revision, {bool head = false}) async {
    if (!settings.enabled || settings.revision != revision) {
      throw StateError('TMDB 已关闭或配置已改变');
    }
    final client = _injected ?? _networkClient();
    _active.add(client);
    try {
      final request = http.Request(head ? 'HEAD' : 'GET', uri)
        ..followRedirects = !head;
      if (!head && settings.usesBearer) {
        request.headers['Authorization'] = 'Bearer ${settings.credential}';
      }
      final stream = await client
          .send(request)
          .timeout(const Duration(seconds: 12));
      final response = await http.Response.fromStream(stream)
          .timeout(const Duration(seconds: 12));
      if (!settings.enabled || settings.revision != revision) {
        throw StateError('TMDB 已关闭或配置已改变');
      }
      return response;
    } finally {
      _active.remove(client);
      if (_injected == null) client.close();
    }
  }

  http.Client _networkClient() {
    final proxy = LumeNet.settings.proxy.trim();
    if (proxy.isEmpty) return http.Client();
    final uri = Uri.tryParse(proxy);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw StateError('TMDB 需要有效的全局 HTTP 代理，或使用 TMDB API 代理地址');
    }
    final port = uri.hasPort
        ? uri.port
        : uri.scheme == 'https'
        ? 443
        : 80;
    return IOClient(HttpClient()..findProxy = (_) => 'PROXY ${uri.host}:$port');
  }

  Future<Uri?> _resolvedBase(int revision) async {
    var uri = TmdbSettings.address(
      settings.apiProxy,
      'https://api.themoviedb.org',
    );
    if (uri.host != 'shturl.cc') return uri;
    for (var i = 0; i < 5; i++) {
      final response = await _get(uri, revision, head: true);
      final location = response.headers['location'];
      if (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null) {
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) return uri;
      throw StateError('API 代理短链解析失败（HTTP ${response.statusCode}）');
    }
    throw StateError('API 代理重定向次数过多');
  }

  Future<Map<String, dynamic>> _json(
    String path,
    int revision,
    Uri? base, {
    Map<String, String> query = const {},
  }) async {
    final response = await _get(
      settings.apiUri(path, base: base, query: query),
      revision,
    );
    if (response.statusCode != 200) {
      throw StateError('TMDB 请求失败（HTTP ${response.statusCode}）');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) throw StateError('TMDB 返回了无效的 JSON');
    return data;
  }

  Future<void> testApi() async {
    if (!settings.configured) throw StateError('请先启用 TMDB 并填写 API Key');
    final revision = settings.revision;
    final base = await _resolvedBase(revision);
    final data = await _json('configuration', revision, base);
    if (data['images'] is! Map) throw StateError('代理未返回有效的 TMDB 配置信息');
  }

  Future<List<int>> testImage() async {
    if (!settings.enabled) throw StateError('请先启用 TMDB');
    final response = await _get(
      Uri.parse(settings.imageUrl('/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg')),
      settings.revision,
    );
    if (response.statusCode != 200) {
      throw StateError('图片代理请求失败（HTTP ${response.statusCode}）');
    }
    return response.bodyBytes;
  }

  String? lastError;
  static String cleanTitle(String value) {
    var title = SearchSettings.toSimplified(value).trim();
    for (var i = 0; i < 3; i++) {
      title = title
          .replaceAll(
            RegExp(
              r'[\s._-]*[（(\[]?(?:国语|粤语|普通话|中字|字幕|高清|超清|蓝光|完整版|更新至\d+集?|全\d+集|第\d+集|2160[pP]|1080[pP]|720[pP]|4[kK])[）)\]]?\s*$',
            ),
            '',
          )
          .trim();
      title = title
          .replaceAll(RegExp(r'[（(\[](?:19|20)\d{2}[）)\]]'), '')
          .replaceAll(RegExp(r'\s+(?:19|20)\d{2}$'), '')
          .trim();
    }
    return title;
  }

  static String normalized(String value) =>
      SearchSettings.toSimplified(value)
          .toLowerCase()
          .replaceAll(RegExp(r'[\s·:：\-《》、，,。.!！?？（）()\[\]]'), '');
  Future<TmdbMetadata?> lookup(String title, {bool force = false}) async {
    lastError = null;
    if (!settings.configured) return null;
    final revision = settings.revision;
    final cacheKey = settings.cacheKey(title);
    try {
      final cached = await settings.cached(cacheKey);
      if (!settings.configured || settings.revision != revision) return null;
      if (!force && cached != null) return cached;
      if (force) await settings.cache(cacheKey, null);
      final base = await _resolvedBase(revision);
      Map? match;
      Map<String, dynamic>? matchedDetails;
      final cleaned = cleanTitle(title);
      final year = RegExp(r'(?:19|20)\d{2}').firstMatch(title)?.group(0);
      for (final query in <String>{title.trim(), cleaned}) {
        if (query.isEmpty) continue;
        final data = await _json(
          'search/multi',
          revision,
          base,
          query: {'query': query, 'language': 'zh-CN'},
        );
        final candidates = (data['results'] as List? ?? [])
            .whereType<Map>()
            .where(
              (row) =>
                  ['movie', 'tv'].contains(row['media_type']) &&
                  row['id'] is int,
            )
            .toList();
        bool same(Object? name) =>
            name is String &&
            normalized(cleanTitle(name)) == normalized(cleaned);
        final exact = candidates
            .where(
              (row) => [
                row['title'],
                row['name'],
                row['original_title'],
                row['original_name'],
              ].any(same),
            )
            .toList();
        if (exact.isNotEmpty) {
          match =
              exact
                  .where(
                    (row) =>
                        year != null &&
                        '${row['release_date'] ?? row['first_air_date'] ?? ''}'
                            .startsWith(year),
                  )
                  .firstOrNull ??
              exact.first;
          break;
        }
        // Check a bounded number of translated aliases; never accept the first search hit blindly.
        for (final candidate in candidates.take(3)) {
          final details = await _json(
            '${candidate['media_type']}/${candidate['id']}',
            revision,
            base,
            query: {
              'language': 'zh-CN',
              'append_to_response':
                  'credits,alternative_titles,translations,recommendations',
            },
          );
          final alternatives = details['alternative_titles'] as Map? ?? {};
          final translations =
              (details['translations'] as Map?)?['translations'] as List? ?? [];
          final aliases = <Object?>[
            details['title'],
            details['name'],
            details['original_title'],
            details['original_name'],
            ...(alternatives['titles'] as List? ??
                    alternatives['results'] as List? ??
                    [])
                .whereType<Map>()
                .map((row) => row['title']),
            ...translations.whereType<Map>().expand(
              (row) => [
                (row['data'] as Map?)?['title'],
                (row['data'] as Map?)?['name'],
              ],
            ),
          ];
          if (aliases.any(same)) {
            match = candidate;
            matchedDetails = details;
            break;
          }
        }
        if (match != null) break;
      }
      if (match == null) return null;
      final type = match['media_type'], id = match['id'];
      final details =
          matchedDetails ??
          await _json(
            '$type/$id',
            revision,
            base,
            query: {
              'language': 'zh-CN',
              'append_to_response':
                  'credits,alternative_titles,translations,recommendations',
            },
          );
      Map<String, dynamic> images = {};
      try {
        images = await _json('$type/$id/images', revision, base);
      } catch (_) {
        lastError = 'TMDB 图片列表暂时无法获取，已保留其他影片资料';
      }
      List<String> paths(String field, Object? fallback, TmdbImageKind kind) {
        final values = (images[field] as List? ?? [])
            .whereType<Map>()
            .map((row) => row['file_path'])
            .whereType<String>()
            .where((path) => path.startsWith('/'))
            .toList();
        if (values.isEmpty && fallback is String && fallback.startsWith('/')) {
          values.add(fallback);
        }
        return values
            .map((path) => settings.imageUrl(path, kind: kind))
            .toList();
      }

      if (!settings.configured || settings.revision != revision) return null;
      final seenRecommendations = <String>{};
      final result = TmdbMetadata(
        recommendations:
            ((details['recommendations'] as Map?)?['results'] as List? ?? [])
                .whereType<Map>()
                .where((row) => row['adult'] != true && row['id'] != id)
                .map(
                  (row) => TmdbRecommendation(
                    title: '${row['title'] ?? row['name'] ?? ''}'.trim(),
                    poster:
                        row['poster_path'] is String &&
                            (row['poster_path'] as String).startsWith('/')
                        ? settings.imageUrl(row['poster_path'] as String)
                        : '',
                  ),
                )
                .where(
                  (item) =>
                      item.title.isNotEmpty &&
                      seenRecommendations.add(normalized(item.title)),
                )
                .take(12)
                .toList(),
        overview: (details['overview'] as String?)?.trim().isNotEmpty == true
            ? details['overview'] as String
            : match['overview'] as String? ?? '',
        posters: paths(
          'posters',
          details['poster_path'] ?? match['poster_path'],
          TmdbImageKind.poster,
        ),
        backdrops: paths(
          'backdrops',
          details['backdrop_path'] ?? match['backdrop_path'],
          TmdbImageKind.backdrop,
        ),
        logos: paths('logos', null, TmdbImageKind.logo),
        videoCovers: paths(
          'stills',
          details['still_path'],
          TmdbImageKind.video,
        ),
        profiles: ((details['credits'] as Map?)?['cast'] as List? ?? [])
            .whereType<Map>()
            .map((row) => row['profile_path'])
            .map(
              (path) => path is String && path.startsWith('/')
                  ? settings.imageUrl(path, kind: TmdbImageKind.profile)
                  : '',
            )
            .toList(),
        rating:
            ((details['vote_average'] ?? match['vote_average']) as num?)
                ?.toDouble() ??
            0,
        voteCount:
            ((details['vote_count'] ?? match['vote_count']) as num?)?.toInt() ??
            0,
        cast: ((details['credits'] as Map?)?['cast'] as List? ?? [])
            .whereType<Map>()
            .map((row) => row['name'])
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .toList(),
      );
      await settings.cache(cacheKey, result);
      return settings.configured && settings.revision == revision
          ? result
          : null;
    } catch (error) {
      // Do not expose URLs or API keys in UI or logs.
      lastError = error is StateError
          ? error.message.toString()
          : error is FormatException
          ? 'TMDB 返回内容无效，请检查 API 代理'
          : 'TMDB 网络请求失败，请检查 API 代理后重试';
      return null;
    }
  }
}
