import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum TmdbPosterStyle { fixed, random, carousel }

class TmdbSettings extends ChangeNotifier {
  TmdbSettings();
  static final instance = TmdbSettings();
  bool enabled = false;
  TmdbPosterStyle posterStyle = TmdbPosterStyle.fixed;
  String apiKey = '', apiProxy = '', imageProxy = '';
  int revision = 0;
  File? _file;
  Future<void> _writes = Future.value();
  Future<void> boot() async {
    try {
      _file = File(
        '${(await getApplicationSupportDirectory()).path}/tmdb_settings.json',
      );
      if (await _file!.exists()) {
        final data =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
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

  Future<void> flush() => _writes;

  Future<void> disconnect() {
    enabled = false;
    apiKey = '';
    apiProxy = '';
    imageProxy = '';
    return save();
  }

  bool get configured => enabled && apiKey.trim().isNotEmpty;
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
        'api_key': apiKey.trim(),
      },
    );
  }

  String imageUrl(String path) {
    final base = address(imageProxy, 'https://image.tmdb.org/t/p/');
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return base
        .replace(path: '$prefix/w500/${path.replaceFirst(RegExp(r'^/+'), '')}')
        .toString();
  }
}

class TmdbMetadata {
  const TmdbMetadata({required this.overview, required this.posters});
  final String overview;
  final List<String> posters;
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
    final client = _injected ?? http.Client();
    _active.add(client);
    try {
      final request = http.Request(head ? 'HEAD' : 'GET', uri)
        ..followRedirects = !head;
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

  static String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s·:：\-《》]'), '');
  Future<TmdbMetadata?> lookup(String title) async {
    if (!settings.configured) return null;
    final revision = settings.revision;
    try {
      final base = await _resolvedBase(revision);
      final data = await _json(
        'search/multi',
        revision,
        base,
        query: {'query': title, 'language': 'zh-CN'},
      );
      final matches = (data['results'] as List? ?? []).whereType<Map>().where(
        (row) =>
            ['movie', 'tv'].contains(row['media_type']) &&
            [
              row['title'],
              row['name'],
              row['original_title'],
              row['original_name'],
            ].whereType<String>().any(
              (name) => normalized(name) == normalized(title),
            ),
      );
      if (matches.isEmpty) return null;
      final match = matches.first;
      final type = match['media_type'];
      final id = match['id'];
      if (id is! int) return null;
      final images = await _json('$type/$id/images', revision, base);
      final paths = (images['posters'] as List? ?? [])
          .whereType<Map>()
          .map((row) => row['file_path'])
          .whereType<String>()
          .where((path) => path.startsWith('/'))
          .toList();
      if (paths.isEmpty && match['poster_path'] is String) {
        paths.add(match['poster_path'] as String);
      }
      if (!settings.configured || settings.revision != revision) return null;
      return TmdbMetadata(
        overview: match['overview'] as String? ?? '',
        posters: paths.map(settings.imageUrl).toList(),
      );
    } catch (_) {
      return null;
    }
  }
}
