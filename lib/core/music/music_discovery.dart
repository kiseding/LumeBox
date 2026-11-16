part of 'music_service.dart';

class _MusicDiscovery {
  _MusicDiscovery(this.service);
  final MusicService service;
  final _cache = <String, ({DateTime time, MusicDiscoveryResult value})>{};

  Future<MusicDiscoveryResult> load({
    String? pluginId,
    bool refresh = false,
  }) async {
    await service.library.load();
    final enabled = service.library.plugins
        .where((p) => p.enabled && (pluginId == null || p.id == pluginId))
        .toList();
    final key = jsonEncode([
      LumeNet.settings.hashCode,
      for (final plugin in enabled) plugin.toJson(),
    ]);
    final cached = _cache[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.time) < const Duration(minutes: 10)) {
      return cached.value;
    }
    final sheets = <MusicCollection>[], charts = <MusicCollection>[];
    final failures = <String>[];
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < enabled.length) {
        NetworkCancellation.current?.check();
        final plugin = enabled[cursor++];
        if (plugin.protocol == MusicProtocol.lx) {
          for (final platform in [
            'wy',
            'kw',
          ].where(plugin.platforms.containsKey)) {
            try {
              final result = await service.catalog.discover(
                plugin.id,
                platform,
              );
              sheets.addAll(result.sheets);
              charts.addAll(result.charts);
              failures.addAll(result.failures);
            } catch (e) {
              NetworkCancellation.current?.check();
              failures.add('${plugin.name} · ${LxCatalog.label(platform)}：$e');
            }
          }
          continue;
        }
        try {
          // Re-read capabilities so plugins installed before discovery support
          // become usable without requiring a reinstall.
          final description = await service._call(plugin, 'describe', const {});
          final caps = description is Map
              ? description['capabilities'] as List? ?? []
              : [];
          for (final method in ['recommend', 'charts']) {
            if (method == 'recommend' &&
                !(caps.contains('getRecommendSheetsByTag') &&
                    caps.contains('getMusicSheetInfo'))) {
              continue;
            }
            if (method == 'charts' &&
                !(caps.contains('getTopLists') &&
                    caps.contains('getTopListDetail'))) {
              continue;
            }
            try {
              final data = await service._call(plugin, method, const {
                'page': 1,
              });
              final rows = method == 'recommend' && data is Map
                  ? data['data']
                  : data;
              if (rows is! List) throw const FormatException('歌单列表格式异常');
              final items = <Map>[];
              for (final row in rows) {
                if (row is! Map) continue;
                if (method == 'charts' && row['data'] is List) {
                  items.addAll((row['data'] as List).whereType<Map>());
                } else {
                  items.add(row);
                }
              }
              for (final item in items.take(method == 'charts' ? 8 : 12)) {
                try {
                  final collection = MusicCollection.parse(
                    plugin.id,
                    item,
                    chart: method == 'charts',
                    subtitle: plugin.name,
                  );
                  (collection.chart ? charts : sheets).add(collection);
                } on FormatException {
                  /* A malformed item does not hide its siblings. */
                }
              }
            } catch (e) {
              NetworkCancellation.current?.check();
              failures.add(
                '${plugin.name} ${method == 'charts' ? '榜单' : '歌单'}：$e',
              );
            }
          }
        } catch (e) {
          NetworkCancellation.current?.check();
          failures.add('${plugin.name}：$e');
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < 3 && i < enabled.length; i++) worker(),
    ]);
    // Stable provider order even when one network request completes faster.
    final order = {for (var i = 0; i < enabled.length; i++) enabled[i].id: i};
    sheets.sort((a, b) => order[a.pluginId]!.compareTo(order[b.pluginId]!));
    charts.sort((a, b) => order[a.pluginId]!.compareTo(order[b.pluginId]!));
    List<MusicCollection> unique(List<MusicCollection> items) {
      final seen = <String>{};
      return items.where((item) => seen.add(item.key)).toList();
    }

    final ranked = unique(charts);
    final hotChart =
        ranked.where((c) => RegExp('热|飙升|流行').hasMatch(c.title)).firstOrNull ??
        ranked.firstOrNull;
    final freshChart = ranked
        .where((c) => RegExp('新歌|新曲|新作').hasMatch(c.title))
        .firstOrNull;
    Future<List<MusicTrack>> preview(MusicCollection? collection) async {
      if (collection == null) return [];
      try {
        return (await tracks(collection)).tracks;
      } catch (e) {
        NetworkCancellation.current?.check();
        failures.add('${collection.title}：$e');
        return [];
      }
    }

    final previews = await Future.wait([
      preview(hotChart),
      preview(freshChart),
    ]);
    NetworkCancellation.current?.check();
    final result = MusicDiscoveryResult(
      sheets: unique(sheets),
      charts: ranked,
      hot: previews[0],
      fresh: previews[1],
      hotChart: hotChart,
      freshChart: freshChart,
      failures: failures,
    );
    // Do not cache outages; keep successful recommendations warm on tab changes.
    if (failures.isEmpty && (sheets.isNotEmpty || charts.isNotEmpty)) {
      if (_cache.length >= 8) _cache.remove(_cache.keys.first);
      _cache[key] = (time: DateTime.now(), value: result);
    }
    return result;
  }

  Future<MusicTrackPage> tracks(
    MusicCollection collection, {
    int page = 1,
  }) async {
    final plugin = service.library.plugin(collection.pluginId);
    if (plugin == null || !plugin.enabled) throw StateError('此歌单的音乐源已停用或删除');
    if (plugin.protocol == MusicProtocol.lx) {
      if (!plugin.platforms.containsKey(collection.platform)) {
        throw StateError('音乐源不再支持此平台');
      }
      return service.catalog.collectionTracks(collection, page: page);
    }
    final data = await service._call(
      plugin,
      collection.chart ? 'chart' : 'sheet',
      {'item': collection.raw, 'page': page},
    );
    if (data is! Map || data['musicList'] is! List) {
      throw const FormatException('歌单未返回有效歌曲');
    }
    final tracks = <MusicTrack>[];
    final seen = <String>{};
    for (final row in data['musicList'] as List) {
      if (row is! Map) continue;
      try {
        final track = MusicTrack.parse(
          plugin.id,
          row,
          primaryKey: plugin.primaryKey,
        );
        if (seen.add(track.key)) tracks.add(track);
      } on FormatException {
        /* Skip malformed records, preserve playable IDs. */
      }
    }
    return MusicTrackPage(
      tracks,
      hasMore: data['isEnd'] != true && tracks.isNotEmpty,
    );
  }
}
