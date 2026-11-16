part of 'music_service.dart';

/// Metadata only: never changes the selected song or its playback address.
class _MusicArtwork {
  _MusicArtwork(this.service);
  final MusicService service;
  final _pending = <String, Future<String?>>{};
  final _cache = <String, (DateTime, String?)>{};

  Future<String?> load(MusicTrack track) async {
    final supplied =
        MusicTrack.artworkUrl(track.cover) ?? MusicTrack.artworkFrom(track.raw);
    if (supplied != null) return supplied;
    final cached = _cache[track.key];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 5)) {
      return cached.$2;
    }
    final existing = _pending[track.key];
    if (existing != null) return existing;
    final task = _lookup(track);
    _pending[track.key] = task;
    try {
      final url = await task;
      _cache[track.key] = (DateTime.now(), url);
      while (_cache.length > 64) {
        _cache.remove(_cache.keys.first);
      }
      return url;
    } finally {
      _pending.remove(track.key);
    }
  }

  static String _normalized(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );

  Future<String?> _lookup(MusicTrack track) async {
    final plugin = service.library.plugin(track.pluginId);
    if (plugin == null || !plugin.enabled) return null;
    final result = await service.search(
      '${track.title} ${track.artist}'.trim(),
      pluginId: track.pluginId,
      platform: track.platform.isEmpty ? null : track.platform,
    );
    final candidates = result.tracks
        .where(
          (t) =>
              t.pluginId == track.pluginId &&
              t.platform == track.platform &&
              MusicTrack.artworkUrl(t.cover) != null,
        )
        .toList();
    final exact = candidates.where((t) => t.id == track.id).firstOrNull;
    if (exact != null) return MusicTrack.artworkUrl(exact.cover);
    if (track.artist.trim().isEmpty) return null;
    final named = candidates
        .where(
          (t) =>
              _normalized(t.title) == _normalized(track.title) &&
              _normalized(t.artist) == _normalized(track.artist) &&
              (track.album.isEmpty ||
                  t.album.isEmpty ||
                  _normalized(track.album) == _normalized(t.album)),
        )
        .toList();
    // Ambiguous editions keep the placeholder rather than borrowing another cover.
    final urls = named.map((t) => MusicTrack.artworkUrl(t.cover)!).toSet();
    return urls.length == 1 ? urls.single : null;
  }
}
