import 'builtin_danmaku_service.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

import '../../../core/util/lume_log.dart';
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
    this.animeId = '',
    this.number,
    this.source = '',
    this.type = '',
    this.year,
  });
  final String id;
  final String title;
  final String episode;
  final String animeId, source, type;
  final int? number, year;
  bool get supplementary => RegExp(
    r'速通|高光|合集|花絮|预告|片花|剪辑|解说|幕后|主题曲|片尾曲|片头曲|trailer|highlights|recap',
    caseSensitive: false,
  ).hasMatch(episode);

  String get workTitle => DandanplayClient.searchTitle(title);
  String get workKey =>
      '${animeId.isEmpty ? workTitle : animeId}|$year|$source';
  String get details => [
    if (year != null) '$year',
    if (type.isNotEmpty) type,
    if (source.isNotEmpty) source,
    if (supplementary) '附加内容／合集，请核对',
  ].join(' · ');
}

/// Official API v2. Source comments and this library are merged by the page.
/// Credentials are stored in iOS Keychain, never embedded in the repository.
class DandanplayClient {
  DandanplayClient({
    required this.credentials,
    http.Client? client,
    Future<Uri> Function()? localService,
  }) : _client = client ?? http.Client(),
       _localService =
           localService ?? BuiltinDanmakuService.instance.ensureStarted;
  final DandanplayCredentials credentials;
  final http.Client _client;
  final Future<Uri> Function() _localService;
  bool _closed = false;
  void close() {
    _closed = true;
    _client.close();
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) =>
      _request(path, query).timeout(const Duration(seconds: 45));

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, String> query,
  ) async {
    Uri? base;
    if (credentials.builtin) {
      try {
        base = await _localService();
      } on UnsupportedError catch (error) {
        throw DandanplayException(error.message?.toString() ?? '内置服务不可用');
      } catch (error) {
        final detail = '$error'.trim();
        throw DandanplayException(
          detail.isEmpty ? '内置弹幕服务启动失败，请重试或完整关闭 App 后重开' : '内置弹幕服务启动失败：$detail',
        );
      }
      if (_closed) throw const DandanplayException('弹幕请求已取消');
    } else {
      base = Uri.tryParse(credentials.baseUrl.trim());
    }
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
    LumeLog.info(
      '[danmaku] ${credentials.builtin
          ? 'builtin'
          : credentials.official
          ? 'official'
          : 'compatible'} ${url.path} -> ${response.statusCode}',
    );
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
      // Local adapter and some compatible servers return a JSON error body even
      // with a non-200 status; surface its reason instead of a bare HTTP code.
      String? reason;
      try {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is Map) reason = '${body['errorMessage'] ?? ''}'.trim();
      } catch (_) {}
      if (reason != null && reason.isNotEmpty) {
        throw DandanplayException('$reason（HTTP ${response.statusCode}）');
      }
      throw DandanplayException('弹幕服务请求失败（HTTP ${response.statusCode}）');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, dynamic> || json['success'] == false) {
      final code = json is Map ? int.tryParse('${json['errorCode']}') : null;
      final message = json is Map ? '${json['errorMessage'] ?? ''}'.trim() : '';
      if (message.isNotEmpty) {
        throw DandanplayException(
          code == null ? message : '$message（错误码 $code）',
        );
      }
      throw DandanplayException(
        code == null ? '弹幕服务返回了无效结果' : '弹幕服务请求未成功（错误码 $code）',
      );
    }
    return json;
  }

  /// A successful empty search also proves the API accepted these credentials.
  Future<void> checkConnection() async {
    if (credentials.builtin) {
      final health = await _get('/_health', {});
      if (health['ok'] != true) throw const DandanplayException('内置服务未就绪');
      // Health only proves the local Node adapter is up. Search is what actually
      // contacts the upstream danmu_api platforms, so surface its failure here
      // instead of showing a misleading "连接成功".
      _parseSearch(
        await _get('/api/v2/search/episodes', {
          'anime': '测试',
          'episode': '1',
          'v2': 'true',
        }),
      );
      return;
    }
    _parseSearch(
      await _get('/api/v2/search/episodes', {
        'anime': '测试',
        'episode': '1',
        'v2': 'true',
      }),
    );
  }

  static String describeError(Object error) => switch (error) {
    DandanplayException() => error.message,
    TimeoutException() => '弹幕服务连接超时，请重试或检查网络',
    PlatformException() || MissingPluginException() => '无法读取或保存本机弹幕凭证，请重试',
    FormatException() => '弹幕服务返回格式不正确，请检查服务地址',
    _ => '弹幕服务连接失败，请检查网络或更换服务',
  };

  Future<List<DandanplayEpisode>> search(String title, {int? episode}) async {
    if (searchTitle(title).isEmpty) {
      throw const DandanplayException('请先填写要匹配的片名');
    }
    final json = await _get('/api/v2/search/episodes', {
      'anime': searchTitle(title),
      'v2': 'true',
      if (episode != null) 'episode': '$episode',
    });
    final direct = _parseSearch(json);
    LumeLog.info(
      '[danmaku] search "${searchTitle(title)}" ep=${episode ?? '-'} -> ${direct.length}',
    );
    if (!credentials.official ||
        direct.any((e) => normalizedTitle(e.title) == normalizedTitle(title))) {
      return direct;
    }
    // Official /search/episodes primarily searches its native catalogue. TV and
    // movie records may live in TMDB and must be resolved through that API.
    //
    // TMDB enrichment is optional: an account without TMDB permission, a
    // transient network error or a 404 here must NOT discard the direct results
    // that already came back. This is why "official search works for custom
    // services but fails for dandanplay" could happen before.
    final extra = <DandanplayEpisode>[];
    try {
      final tmdb = await _get('/api/v2/search/tmdb', {
        'keyword': searchTitle(title),
      });
      final candidates = (tmdb['animes'] as List? ?? [])
          .whereType<Map>()
          .where(
            (e) =>
                normalizedTitle('${e['animeTitle'] ?? ''}') ==
                normalizedTitle(title),
          )
          .take(3);
      for (final work in candidates) {
        final id = '${work['bangumiId'] ?? ''}';
        if (!RegExp(r'^tmdb-(?:tv|movie)-[0-9]+$').hasMatch(id)) continue;
        final detail = await _get(
          '/api/v2/bangumi/${Uri.encodeComponent(id)}',
          {},
        );
        final bangumi = detail['bangumi'];
        if (bangumi is! Map) continue;
        extra.addAll(
          _parseSearch({
            'animes': [
              {
                ...work,
                ...bangumi,
                'animeTitle': work['animeTitle'],
                'animeId': id,
                'source': 'TMDB',
              },
            ],
          }).where((e) => episode == null || e.number == episode),
        );
      }
    } catch (_) {
      // Keep the native-catalogue results; manual matching can still use them.
    }
    final ids = <String>{};
    return [...extra, ...direct].where((e) => ids.add(e.id)).toList();
  }

  static List<DandanplayEpisode> _parseSearch(Map<String, dynamic> json) {
    final animes = json['animes'];
    if (animes is! List) {
      throw const DandanplayException('服务未返回作品列表，请检查弹幕服务地址');
    }
    final result = <DandanplayEpisode>[];
    for (final anime in animes) {
      if (anime is! Map) continue;
      final episodes = anime['episodes'];
      if (episodes is! List) continue;
      final animeTitle = '${anime['animeTitle'] ?? ''}'.trim();
      final source = '${anime['source'] ?? ''}'.trim();
      final inferredSource =
          RegExp(
            r'from\s+([\w-]+)\s*$',
            caseSensitive: false,
          ).firstMatch(animeTitle)?.group(1) ??
          '';
      final year =
          int.tryParse('${anime['startDate'] ?? ''}'.split('-').first) ??
          int.tryParse(
            RegExp(r'[（(\[]((?:19|20)\d{2})[）)\]]')
                    .firstMatch(animeTitle)
                    ?.group(1) ??
                '',
          );
      for (final item in episodes) {
        if (item is! Map) continue;
        final id = '${item['episodeId'] ?? ''}';
        if (id.isEmpty || id == 'null' || animeTitle.isEmpty) continue;
        final episodeTitle = '${item['episodeTitle'] ?? item['title'] ?? ''}';
        result.add(
          DandanplayEpisode(
            id: id,
            title: animeTitle,
            episode: episodeTitle,
            animeId: '${anime['animeId'] ?? anime['bangumiId'] ?? ''}',
            source: source.isEmpty ? inferredSource : source,
            type: '${anime['typeDescription'] ?? anime['type'] ?? ''}',
            year: year,
            number:
                int.tryParse('${item['episodeNumber'] ?? ''}') ??
                parsedEpisodeNumber(episodeTitle),
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
      // The local upstream caches comment results. If its first upstream fetch
      // failed and cached an empty list, retrying immediately would keep
      // returning 0. A changing cache key makes "重新加载本集" actually retry.
      if (credentials.builtin) '_': '${DateTime.now().microsecondsSinceEpoch}',
    });
    if (json['comments'] is! List) {
      throw const DandanplayException('服务未返回弹幕列表，请重试或检查弹幕服务地址');
    }
    final track = parseComments(json);
    LumeLog.info('[danmaku] comments $id -> ${track.length}');
    return track;
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
      .replaceFirst(
        RegExp(
          r'(?:\s+from\s+|(?<=[）)】\]])\s*from\s*)[\w-]+\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'[（(\[]((?:19|20)\d{2})[）)\]]'), '')
      .replaceAllMapped(
        RegExp(r'【[^】]*】'),
        (match) =>
            RegExp(r'第.+季|season', caseSensitive: false).hasMatch(match[0]!)
            ? match[0]!
            : '',
      )
      .trim();

  static String normalizedTitle(String title) =>
      searchTitle(title)
          .toLowerCase()
          .replaceAll(RegExp(r'[\s·・:：\-—_，,。.!！?？《》「」【】\[\]（）()]'), '');

  static int episodeNumber(String chapterTitle, {required int chapterIndex}) {
    return parsedEpisodeNumber(chapterTitle) ?? chapterIndex + 1;
  }

  /// Unknown episode titles stay unknown when validating server search results.
  static int? parsedEpisodeNumber(String chapterTitle) {
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
    final suffix = RegExp(r'(?:^|[_\s-])(\d{1,3})(?:\s|$)').firstMatch(title);
    if (suffix != null) return int.tryParse(suffix.group(1)!);
    final chinese = RegExp(r'第\s*([零〇一二两三四五六七八九十百]+)\s*[集话話期]')
        .firstMatch(title)
        ?.group(1);
    if (chinese != null) {
      const digits = {
        '零': 0,
        '〇': 0,
        '一': 1,
        '二': 2,
        '两': 2,
        '三': 3,
        '四': 4,
        '五': 5,
        '六': 6,
        '七': 7,
        '八': 8,
        '九': 9,
      };
      var total = 0, digit = 0;
      for (final char in chinese.split('')) {
        if (char == '十' || char == '百') {
          total += (digit == 0 ? 1 : digit) * (char == '十' ? 10 : 100);
          digit = 0;
        } else {
          digit = digits[char]!;
        }
      }
      return total + digit > 0 ? total + digit : null;
    }
    return null;
  }

  static DandanplayEpisode? exactMatch(
    List<DandanplayEpisode> items,
    String title, {
    int? episode,
  }) {
    final exact = items
        .where(
          (item) =>
              !item.supplementary &&
              normalizedTitle(item.title) == normalizedTitle(title) &&
              (episode == null ||
                  (item.number ?? parsedEpisodeNumber(item.episode)) ==
                      episode),
        )
        .toList();
    return exact.length == 1 ? exact.single : null;
  }
}
