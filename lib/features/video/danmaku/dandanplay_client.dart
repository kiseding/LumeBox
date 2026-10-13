import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import 'danmaku_models.dart';

class DandanplayCredentials {
  const DandanplayCredentials(
    this.appId,
    this.appSecret, {
    this.baseUrl = defaultBase,
  });
  static const defaultBase = 'https://danmu.cynn.top/cynnsq';
  static const officialBase = 'https://api.dandanplay.net';
  final String baseUrl;
  bool get official => Uri.parse(baseUrl).host == 'api.dandanplay.net';
  final String appId;
  final String appSecret;
  bool get configured => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  static const _channel = MethodChannel('lumebox/danmaku_credentials');
  static Future<DandanplayCredentials> load() async {
    try {
      final value = await _channel.invokeMapMethod<String, String>('read');
      return DandanplayCredentials(
        value?['appId'] ?? '',
        value?['appSecret'] ?? '',
        baseUrl: value?['baseUrl'] ?? defaultBase,
      );
    } on MissingPluginException {
      return const DandanplayCredentials('', '');
    }
  }

  Future<void> save() => _channel.invokeMethod<void>('write', {
    'appId': appId.trim(),
    'appSecret': appSecret.trim(),
    'baseUrl': baseUrl.trim(),
  });
}

class DandanplayEpisode {
  const DandanplayEpisode({
    required this.id,
    required this.title,
    required this.episode,
  });
  final String id;
  final String title;
  final String episode;
}

/// Official API v2. Source comments and this library are merged by the page.
/// Credentials are stored in iOS Keychain, never embedded in the repository.
class DandanplayClient {
  DandanplayClient({required this.credentials, http.Client? client})
    : _client = client ?? http.Client();
  final DandanplayCredentials credentials;
  final http.Client _client;
  void close() => _client.close();

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final base = Uri.tryParse(credentials.baseUrl.trim());
    if (base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw StateError('请填写完整的 HTTPS 弹幕服务地址');
    }
    if (credentials.official && !credentials.configured) {
      throw StateError('请先配置弹弹play应用凭证');
    }
    final url = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}$path',
      queryParameters: query,
    );
    final timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final response = await _client
        .get(
          url,
          headers: {
            if (credentials.official) ...{
              'X-AppId': credentials.appId,
              'X-Timestamp': timestamp,
              'X-Signature': base64Encode(
                sha256
                    .convert(
                      utf8.encode(
                        '${credentials.appId}$timestamp$path${credentials.appSecret}',
                      ),
                    )
                    .bytes,
              ),
            },
            'Accept': 'application/json',
            'User-Agent': 'LumeBox/1.0',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw StateError('弹弹play凭证未通过验证，请检查应用审核状态和凭证');
    }
    if (response.statusCode != 200) throw StateError('弹弹play服务暂不可用');
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, dynamic> || json['success'] == false) {
      throw StateError('弹弹play请求未成功，请稍后重试');
    }
    return json;
  }

  Future<List<DandanplayEpisode>> search(String title, {int? episode}) async {
    final json = await _get('/api/v2/search/episodes', {
      'anime': title,
      'v2': 'true',
      if (episode != null) 'episode': '$episode',
    });
    final result = <DandanplayEpisode>[];
    for (final anime in (json['animes'] as List? ?? const [])) {
      if (anime is! Map) continue;
      for (final item in (anime['episodes'] as List? ?? const [])) {
        if (item is! Map) continue;
        final id = '${item['episodeId'] ?? ''}';
        if (id.isEmpty) continue;
        result.add(
          DandanplayEpisode(
            id: id,
            title: '${anime['animeTitle'] ?? ''}',
            episode: '${item['episodeTitle'] ?? ''}',
          ),
        );
      }
    }
    return result;
  }

  Future<DanmakuTrack> comments(String id) async => parseComments(
    await _get('/api/v2/comment/${Uri.encodeComponent(id)}', {
      'withRelated': 'true',
      'format': 'json',
    }),
  );

  static DanmakuTrack parseComments(Map<String, dynamic> json) {
    final result = <DanmakuItem>[];
    for (final raw in (json['comments'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final fields = '${raw['p'] ?? ''}'.split(',');
      final seconds = fields.isEmpty ? null : double.tryParse(fields[0]);
      final text = '${raw['m'] ?? ''}'.trim();
      if (seconds == null ||
          !seconds.isFinite ||
          seconds < 0 ||
          text.isEmpty ||
          fields.length < 3) {
        continue;
      }
      result.add(
        DanmakuItem(
          time: Duration(milliseconds: (seconds * 1000).round()),
          text: text,
          mode: DanmakuMode.fromId(fields[1]),
          color: int.tryParse(fields[2]) ?? 0xFFFFFF,
        ),
      );
    }
    return DanmakuTrack.parse(result);
  }

  static String normalizedTitle(String title) => title
      .toLowerCase()
      .replaceFirst(RegExp(r'\s*from\s+.*$'), '')
      .replaceAll(RegExp(r'[（(]\d{4}[）)]|【[^】]*】'), '')
      .replaceAll(RegExp(r'[\s·・:：\-—_，,。.!！?？《》「」【】\[\]（）()]'), '');

  static DandanplayEpisode? exactMatch(
    List<DandanplayEpisode> items,
    String title,
  ) {
    final exact = items
        .where((item) => normalizedTitle(item.title) == normalizedTitle(title))
        .toList();
    return exact.length == 1 ? exact.single : null;
  }
}
