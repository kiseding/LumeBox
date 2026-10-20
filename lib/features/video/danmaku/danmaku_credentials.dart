import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class DandanplayCredentials {
  const DandanplayCredentials(
    this.appId,
    this.appSecret, {
    this.baseUrl = defaultBase,
  });
  static const defaultBase = 'https://danmu.cynn.top/cynnsq';
  static const officialBase = 'https://api.dandanplay.net';
  final String baseUrl;
  final String appId;
  final String appSecret;
  bool get official => isOfficial(Uri.tryParse(baseUrl.trim()));
  bool get configured => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  static bool isOfficial(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'api.dandanplay.net' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  static Future<DandanplayCredentials> load() async {
    final value = await DanmakuSourcesStore.read();
    return DandanplayCredentials(
      value['appId'] ?? '',
      value['appSecret'] ?? '',
      baseUrl: value['baseUrl'] ?? defaultBase,
    );
  }

  Future<void> save() => DanmakuSourcesStore.saveCredentials(this);
}

/// Both players and settings use the same device-only native credential store.
/// The old iOS single-service item is read only when no profile has been saved.
class DanmakuSourcesStore {
  static final revision = ValueNotifier<int>(0);
  static const channel = MethodChannel('lumebox/reference_danmaku_credentials');
  static const _legacy = MethodChannel('lumebox/danmaku_credentials');

  static Future<Map<String, String>> read() async {
    Map<String, String>? data;
    try {
      data = await channel.invokeMapMethod<String, String>('read');
    } on MissingPluginException {
      // Older hosts only registered the single-service channel.
    }
    if (data == null || data.isEmpty) {
      try {
        data = await _legacy.invokeMapMethod<String, String>('read');
      } on MissingPluginException {
        return {};
      }
    }
    if (data == null) return {};
    if (!data.containsKey('profilesJson')) return data;
    final sources = profiles(data);
    final selected = sources
        .where((s) => s['id'] == data!['activeId'])
        .firstOrNull;
    return {
      ...data,
      'baseUrl': selected?['url'] ?? DandanplayCredentials.defaultBase,
      'appId': selected?['appId'] ?? '',
      'appSecret': selected?['appSecret'] ?? '',
    };
  }

  static List<Map<String, String>> profiles(Map<String, String> data) {
    final raw = jsonDecode(data['profilesJson'] ?? '[]');
    if (raw is! List) return [];
    return [
      for (final row in raw)
        if (row is Map)
          {
            for (final entry in row.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          },
    ];
  }

  static Future<void> save(
    List<Map<String, String>> sources,
    String active,
  ) async {
    final selected = sources.where((s) => s['id'] == active).firstOrNull;
    await channel.invokeMethod<void>('write', {
      'profilesJson': jsonEncode(sources),
      'activeId': active,
      'baseUrl': selected?['url'] ?? DandanplayCredentials.defaultBase,
      'appId': selected?['appId'] ?? '',
      'appSecret': selected?['appSecret'] ?? '',
    });
    revision.value++;
  }

  static Future<void> saveCredentials(DandanplayCredentials config) async {
    final data = await read();
    final sources = profiles(data);
    final active = data['activeId'];
    final existing = sources.where((s) => s['id'] == active).firstOrNull;
    final id =
        existing?['id'] ?? 'service-${DateTime.now().microsecondsSinceEpoch}';
    final base = config.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final next = {
      'id': id,
      'name':
          existing?['name'] ??
          (config.official ? '弹弹play 开放平台' : Uri.parse(base).host),
      'type': config.official ? 'official' : 'logvar',
      'url': base,
      'appId': config.appId.trim(),
      'appSecret': config.appSecret.trim(),
    };
    await save([
      for (final source in sources)
        if (source['id'] != id) source,
      next,
    ], id);
  }
}
