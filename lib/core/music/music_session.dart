import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio_book/audio_book_player.dart';
import '../audio_book/audio_book_track.dart';
import '../media/media_library.dart';
import '../session/section.dart';
import 'music_library.dart';
import 'music_models.dart';
import 'music_service.dart';

/// Share the existing audio owner: just_audio_background supports one player.
class MusicSession extends ChangeNotifier {
  MusicSession({
    AudioBookSession? audio,
    MusicService? service,
    MusicLibrary? library,
  }) : audio = audio ?? AudioBookSession.instance,
       service = service ?? MusicService.instance,
       library = library ?? MusicLibrary.instance {
    this.audio.addListener(_changed);
  }
  static final instance = MusicSession();
  static final visible = ValueNotifier<bool>(false);
  static const resourceId = 'lumebox:music:queue';
  final AudioBookSession audio;
  final MusicService service;
  final MusicLibrary library;
  List<MusicTrack> _queue = [];
  List<MusicTrack> get queue => List.unmodifiable(_queue);
  bool get active => audio.resource?.id == resourceId;
  MusicTrack? get current =>
      active && audio.current < _queue.length && audio.current >= 0
      ? _queue[audio.current]
      : null;
  String? _last;
  String? error;
  bool opening = false;
  bool _miniPlayerHidden = false;
  bool get miniPlayerHidden => _miniPlayerHidden;

  void hideMiniPlayer() {
    _miniPlayerHidden = true;
    _changed();
  }

  void showMiniPlayer() {
    _miniPlayerHidden = false;
    _changed();
  }

  int _request = 0;
  bool _disposed = false;
  final _artworkRequests = <String, DateTime>{};
  void _completeArtwork(MusicTrack track) {
    if (MusicTrack.artworkUrl(track.cover) != null) return;
    final previous = _artworkRequests[track.key];
    if (previous != null &&
        DateTime.now().difference(previous) < const Duration(minutes: 5)) {
      return;
    }
    _artworkRequests[track.key] = DateTime.now();
    while (_artworkRequests.length > 128) {
      _artworkRequests.remove(_artworkRequests.keys.first);
    }
    unawaited(() async {
      try {
        final cover = await service.artwork(track);
        if (_disposed || cover == null) return;
        for (var i = 0; i < _queue.length; i++) {
          if (_queue[i].key == track.key) {
            _queue[i] = _queue[i].withCover(cover);
          }
        }
        await library.rememberArtwork(track.withCover(cover));
        if (!_disposed) notifyListeners();
      } catch (_) {
        // Missing metadata must never interrupt audio playback.
      }
    }());
  }

  Future<void> retry() async {
    error = null;
    if (active) {
      await audio.retry();
    } else if (_queue.isNotEmpty) {
      await play(
        _queue,
        index: audio.current.clamp(0, _queue.length - 1),
        restart: false,
      );
    }
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    final track = current;
    if (track != null && !opening && !audio.loading) _completeArtwork(track);
    visible.value = track != null && !_miniPlayerHidden;
    if (track != null &&
        track.key != _last &&
        !audio.loading &&
        audio.error == null) {
      _last = track.key;
      unawaited(library.remember(track).catchError((Object _) {}));
    }
    notifyListeners();
  }

  Future<void> resume() async {
    if (active && current != null) {
      if (!audio.playing) await audio.play();
      return;
    }
    await library.load();
    final saved = (library.queue.isNotEmpty ? library.queue : library.recent)
        .where((track) => library.plugin(track.pluginId)?.enabled == true)
        .toList();
    if (saved.isEmpty) return;
    final last = library.recent.firstOrNull;
    final index = saved.indexWhere((track) => track.key == last?.key);
    await play(saved, index: index < 0 ? 0 : index, restart: false);
  }

  Future<void> play(
    List<MusicTrack> tracks, {
    int index = 0,
    bool restart = true,
  }) async {
    if (tracks.isEmpty) return;
    final snapshot = List<MusicTrack>.of(tracks);
    final request = ++_request;
    error = null;
    opening = true;
    notifyListeners();
    try {
      await library.load();
      if (request != _request) return;
      library.queue
        ..clear()
        ..addAll(snapshot);
      await library.save();
      if (request != _request) return;
      _queue = snapshot;
      final episodes = [
        for (final t in _queue) ResourceEpisode(id: t.key, title: t.title),
      ];
      // Music always starts at normal speed. Book speed remains a book setting.
      await audio.open(
        MediaResource(
          id: resourceId,
          title: '音乐',
          kind: ResourceKind.audioBook,
          destination: Section.video,
          episodes: episodes,
        ),
        [
          for (var i = 0; i < _queue.length; i++)
            AudioBookTrack(
              id: 'music:${_queue[i].key}',
              episode: episodes[i],
              album: _queue[i].album.isEmpty ? '音乐' : _queue[i].album,
              artist: _queue[i].artist,
              cover: _queue[i].cover,
              music: true,
              resolve: () => service.resolve(snapshot[i]),
            ),
        ],
        index: index.clamp(0, _queue.length - 1),
        restart: restart,
      );
    } catch (e) {
      if (request == _request) error = '$e';
    }
    if (request == _request) opening = false;
    if (current != null) _completeArtwork(current!);
    notifyListeners();
  }

  Future<void> toggle() => audio.playing ? audio.pause() : audio.play();
  Future<void> select(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await audio.playChapter(index);
  }

  Future<void> next() => select(audio.current + 1);
  Future<void> previous() => select(audio.current - 1);
  @override
  void dispose() {
    _disposed = true;
    audio.removeListener(_changed);
    super.dispose();
  }
}
