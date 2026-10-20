import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import 'danmaku_models.dart';
import 'danmaku_credentials.dart';

export 'danmaku_credentials.dart';

class DandanplayException implements Exception {
  const DandanplayException(this.message);
  final String message;
  @override
  String toString() => message;
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

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) =>
      _request(path, query).timeout(const Duration(seconds: 30));

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, String> query,
  ) async {
    final base = Uri.tryParse(credentials.baseUrl.trim());
    if (base == null ||
        !['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const DandanplayException('请填写完整的弹幕服务地址，保留路径前缀');
    }
    if (credentials.official && !credentials.configured) {
      throw const DandanplayException('请先配置弹弹play应用 AppId 和 AppSecret');
    }
    if (base.host == 'api.dandanplay.net' && !credentials.official) {
      throw const DandanplayException('官方服务地址请使用 https://api.dandanplay.net');
    }
    var url = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}$path',
      queryParameters: query,
    );
    http.Response? response;
    // The official comments endpoint redirects to a CDN. Handle redirects
    // explicitly so signatures never follow the request to another origin.
    for (var redirects = 0; redirects <= 5; redirects++) {
      final timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final request = http.Request('GET', url)..followRedirects = false;
      request.headers.addAll({
        if (credentials.official && DandanplayCredentials.isOfficial(url)) ...{
          'X-AppId': credentials.appId.trim(),
          'X-Timestamp': timestamp,
          'X-Signature': base64Encode(
            sha256
                .convert(
                  utf8.encode(
                    '${credentials.appId.trim()}$timestamp${url.path}${credentials.appSecret.trim()}',
                  ),
                )
                .bytes,
          ),
        },
        'Accept': 'application/json',
        'User-Agent': 'LumeBox/1.0',
      });
      response = await http.Response.fromStream(await _client.send(request));
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
      final location = response.headers['location'];
      final next = location == null ? null : url.resolve(location);
      if (redirects == 5 ||
          next == null ||
          !['http', 'https'].contains(next.scheme) ||
          next.host.isEmpty ||
          next.userInfo.isNotEmpty ||
          (url.scheme == 'https' && next.scheme != 'https')) {
        throw const DandanplayException('弹幕服务跳转无效，请检查服务地址');
      }
      url = next;
    }
    response = response!;
    if (response.statusCode == 401 || response.statusCode == 403) {
      final reason = switch (response.headers['x-error-message']) {
        'Invalid Timestamp' => '设备时间不准确，请开启系统自动设置日期与时间',
        'Invalid AppId' => 'AppId 无效或与 AppSecret 不配对，请核对应用凭证',
        'Invalid AppSecret' ||
        'Invalid Signature' => 'AppSecret 无效或签名未通过，请检查密钥是否复制完整及设备时间',
        'Missing Authentication Headers' => '服务未收到应用鉴权信息，请检查服务地址',
        _ =>
          credentials.official
              ? '应用凭证未通过验证，请检查 AppId、AppSecret 和应用状态'
              : '兼容服务拒绝访问，请检查地址中的访问令牌或更换服务',
      };
      throw DandanplayException('$reason（HTTP ${response.statusCode}）');
    }
    if (response.statusCode != 200) {
      throw DandanplayException('弹幕服务请求失败（HTTP ${response.statusCode}）');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, dynamic> || json['success'] == false) {
      final code = json is Map ? int.tryParse('${json['errorCode']}') : null;
      throw DandanplayException(
        code == null ? '弹幕服务返回了无效结果' : '弹幕服务请求未成功（错误码 $code）',
      );
    }
    return json;
  }

  /// A successful empty search also proves the API accepted these credentials.
  Future<void> checkConnection() async {
    await search('测试', episode: 1);
  }

  static String describeError(Object error) => switch (error) {
    DandanplayException() => error.message,
    TimeoutException() => '弹幕服务连接超时，请重试或检查网络',
    PlatformException() || MissingPluginException() => '无法读取或保存本机弹幕凭证，请重试',
    FormatException() => '弹幕服务返回格式不正确，请检查服务地址',
    _ => '弹幕服务连接失败，请检查网络或更换服务',
  };

  Future<List<DandanplayEpisode>> search(String title, {int? episode}) async {
    final json = await _get('/api/v2/search/episodes', {
      'anime': searchTitle(title),
      'v2': 'true',
      if (episode != null) 'episode': '$episode',
    });
    final animes = json['animes'];
    if (animes is! List) {
      throw const DandanplayException('服务未返回作品列表，请检查弹幕服务地址');
    }
    final result = <DandanplayEpisode>[];
    for (final anime in animes) {
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

  Future<DanmakuTrack> comments(String id) async {
    final json = await _get('/api/v2/comment/${Uri.encodeComponent(id)}', {
      'withRelated': 'true',
      'format': 'json',
    });
    if (json['comments'] is! List) {
      throw const DandanplayException('服务未返回弹幕列表，请重试或检查弹幕服务地址');
    }
    return parseComments(json);
  }

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

  static String searchTitle(String title) => title
      .replaceFirst(RegExp(r'\s*from\s+.*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[（(]\d{4}[）)]|【[^】]*】'), '')
      .trim();

  static String normalizedTitle(String title) =>
      searchTitle(title)
          .toLowerCase()
          .replaceAll(RegExp(r'[\s·・:：\-—_，,。.!！?？《》「」【】\[\]（）()]'), '');

  static int episodeNumber(String chapterTitle, {required int chapterIndex}) {
    final title = chapterTitle.trim();
    final match = RegExp(
      r'第\s*(\d+)\s*[集话話期]|\b(?:S\d+\s*)?E(?:P)?\s*(\d+)\b',
      caseSensitive: false,
    ).firstMatch(title);
    final number = int.tryParse(match?.group(1) ?? match?.group(2) ?? title);
    if (number != null && number > 0) return number;
    if (RegExp(
      r'正片|蓝光|藍光|高清|超清|1080|2160|720|4K|\b(?:HD|BD|FHD|UHD)\b',
      caseSensitive: false,
    ).hasMatch(title)) {
      return 1;
    }
    return chapterIndex + 1;
  }

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
