import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/audio_book/audio_book_player.dart';
import 'package:lume_box/core/audio_book/audio_book_track.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/music/music_library.dart';
import 'package:lume_box/core/music/music_models.dart';
import 'package:lume_box/core/music/music_service.dart';
import 'package:lume_box/core/music/music_session.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/features/music/music_page.dart';

class _Audio extends AudioBookSession {
  int retries = 0;
  @override
  Future<void> retry() async {
    retries++;
    error = null;
    notifyListeners();
  }

  final entered = Completer<void>(), ready = Completer<void>();
  List<AudioBookTrack> tracks = [];
  @override
  Future<void> open(
    MediaResource entry,
    List<AudioBookTrack> sources, {
    int? index,
    Duration? initialPosition,
    bool restart = false,
  }) async {
    tracks = sources;
    resource = entry;
    current = index ?? 0;
    notifyListeners();
    entered.complete();
    await ready.future;
  }

  @override
  Future<void> playChapter(int index) async {
    current = index;
    notifyListeners();
  }
}

class _ResumeAudio extends AudioBookSession {
  bool? restarted;
  int? requested;
  @override
  Future<void> open(
    MediaResource entry,
    List<AudioBookTrack> sources, {
    int? index,
    Duration? initialPosition,
    bool restart = false,
  }) async {
    restarted = restart;
    requested = index;
  }
}

class _PlayerService extends MusicService {
  _PlayerService({required super.library});

  @override
  Future<MusicLyrics> lyrics(MusicTrack track) async => const MusicLyrics(
    original: '[00:00.00]第一句歌词\n[00:20.00]背靠着背 看着日落\n[00:40.00]下一句歌词',
  );
}

class _LateArtworkService extends _PlayerService {
  _LateArtworkService({required super.library});
  final first = Completer<String?>(), second = Completer<String?>();
  @override
  Future<String?> artwork(MusicTrack track) =>
      track.id == 'a' ? first.future : second.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('旧歌曲封面晚到不会覆盖当前歌曲，补全结果仍保存到原歌曲', () async {
    final root = await Directory.systemTemp.createTemp('music-late-artwork-');
    final library = MusicLibrary(directory: root), audio = _Audio();
    final service = _LateArtworkService(library: library);
    final music = MusicSession(
      library: library,
      audio: audio,
      service: service,
    );
    audio.ready.complete();
    try {
      await music.play(const [
        MusicTrack(pluginId: 'p', id: 'a', title: '第一首'),
        MusicTrack(pluginId: 'p', id: 'b', title: '第二首'),
      ]);
      await music.next();
      service.first.complete('https://example.com/first.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(music.current?.id, 'b');
      expect(music.current?.cover, isNull);
      expect(music.queue.first.cover, 'https://example.com/first.jpg');
      service.second.complete('https://example.com/second.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(music.current?.cover, 'https://example.com/second.jpg');
      expect(library.queue.first.cover, 'https://example.com/first.jpg');
      expect(audio.tracks.map((t) => t.id).toSet(), hasLength(2));
    } finally {
      music.dispose();
      audio.dispose();
      service.dispose();
      await library.save();
      library.dispose();
      await root.delete(recursive: true);
      MusicSession.visible.value = false;
    }
  });
  testWidgets('播放页封面、歌词和队列在窄屏大字体及横屏保持可用', (tester) async {
    final root = Directory.systemTemp.createTempSync('music-player-');
    late MusicLibrary library;
    late _Audio audio;
    late _PlayerService service;
    late MusicSession music;
    await tester.runAsync(() async {
      library = MusicLibrary(directory: root);
      audio = _Audio();
      service = _PlayerService(library: library);
      music = MusicSession(audio: audio, service: service, library: library);
      audio.ready.complete();
      await music.play(const [
        MusicTrack(pluginId: 'test', id: 'a', title: '海', artist: '任东'),
        MusicTrack(pluginId: 'test', id: 'b', title: '第二首'),
      ]);
    });
    audio.progress.value = (
      const Duration(seconds: 30),
      const Duration(seconds: 120),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [
      const Size(440, 956),
      const Size(320, 700),
      const Size(844, 390),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorSchemeSeed: Colors.deepPurple),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(size.width == 320 ? 2 : 1),
            ),
            child: MusicPlayerPage(session: music),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('music-album-fallback')), findsOneWidget);
      expect(find.text('背靠着背 看着日落'), findsOneWidget);
      final art = tester.getSize(find.byKey(const Key('music-album-artwork')));
      expect(art.width, art.height);
      expect(art.width, lessThanOrEqualTo(310));
      if (size.width > size.height) {
        expect(find.byKey(const Key('music-player-landscape')), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const Key('music-album-artwork'))).right,
          lessThan(tester.getRect(find.text('海')).left),
        );
      }
      expect(tester.takeException(), isNull);
    }
    final slider = find.byKey(const Key('music-seek-slider'));
    final beforeLyricChange = tester.getRect(slider);
    audio.progress.value = (
      const Duration(seconds: 60),
      const Duration(seconds: 120),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(slider), beforeLyricChange);
    audio.loading = true;
    audio.notifyListeners();
    await tester.pump();
    expect(find.byKey(const Key('music-play-buffering')), findsOneWidget);
    audio.loading = false;
    audio.error = 'Bad state: ${'long network error ' * 80}';
    audio.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('long network error'), findsNothing);
    await tester.ensureVisible(find.byTooltip('重试播放'));
    await tester.tap(find.byTooltip('重试播放'));
    await tester.pumpAndSettle();
    expect(audio.retries, 1);
    await tester.tap(find.byTooltip('播放设置'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ChoiceChip, '无损'));
      await library.save();
    });
    await tester.pumpAndSettle();
    expect(library.quality, 'high');
    await tester.ensureVisible(find.widgetWithText(ActionChip, '30 分钟'));
    await tester.tap(find.widgetWithText(ActionChip, '30 分钟'));
    await tester.pumpAndSettle();
    expect(audio.sleepAt, isNotNull);
    await tester.tap(find.widgetWithText(ActionChip, '取消定时'));
    await tester.pumpAndSettle();
    expect(audio.sleepAt, isNull);
    Navigator.of(tester.element(find.text('播放设置').last)).pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('下一首'));
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('下一首'));
      await library.save();
    });
    await tester.pumpAndSettle();
    expect(music.current?.title, '第二首');
    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '第二首'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    audio.dispose();
    service.dispose();
    await tester.runAsync(() async {
      await library.save();
      library.dispose();
      await root.delete(recursive: true);
    });
    MusicSession.visible.value = false;
  });
  testWidgets('迷你播放器窄屏大字体无溢出，隐藏保留播放与队列且可恢复', (tester) async {
    final root = Directory.systemTemp.createTempSync('music-mini-');
    late MusicLibrary library;
    late _Audio audio;
    late MusicService service;
    late MusicSession music;
    await tester.runAsync(() async {
      library = MusicLibrary(directory: root);
      audio = _Audio();
      service = MusicService(library: library);
      music = MusicSession(audio: audio, service: service, library: library);
      audio.ready.complete();
      await music.play(const [
        MusicTrack(
          pluginId: 'test',
          id: 'one',
          title: '很长的歌曲名称用于窄屏布局',
          artist: '歌手名称',
        ),
        MusicTrack(pluginId: 'test', id: 'two', title: '下一首'),
      ]);
    });
    audio.playing = true;
    audio.position = const Duration(seconds: 30);
    audio.duration = const Duration(seconds: 120);
    audio.notifyListeners();
    await tester.binding.setSurfaceSize(const Size(320, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(child: MusicMiniPlayer(session: music)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('music-mini-progress')),
          )
          .value,
      .25,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('隐藏迷你播放器（继续播放）'));
    await tester.pumpAndSettle();
    expect(MusicSession.visible.value, isFalse);
    expect(find.byKey(const Key('music-mini-player')), findsNothing);
    expect(audio.playing, isTrue);
    expect(audio.position, const Duration(seconds: 30));
    expect(music.queue, hasLength(2));
    await tester.runAsync(() async {
      await music.next();
      audio.notifyListeners();
      await library.save();
    });
    await tester.pump();
    expect(MusicSession.visible.value, isFalse);
    expect(find.byKey(const Key('music-mini-player')), findsNothing);
    music.showMiniPlayer();
    await tester.pumpAndSettle();
    expect(MusicSession.visible.value, isTrue);
    expect(find.text('下一首'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    music.dispose();
    audio.dispose();
    service.dispose();
    await tester.runAsync(() async {
      await library.save();
      library.dispose();
      await root.delete(recursive: true);
    });
    MusicSession.visible.value = false;
  });
  test(
    'resume restores the last queue item without resetting its saved position',
    () async {
      final root = await Directory.systemTemp.createTemp('music-resume-');
      final library = MusicLibrary(directory: root), audio = _ResumeAudio();
      await library.load();
      library.plugins.add(
        const MusicPlugin(
          id: 'p',
          name: 'Source',
          protocol: MusicProtocol.musicFree,
        ),
      );
      const a = MusicTrack(pluginId: 'p', id: 'a', title: 'One');
      const b = MusicTrack(pluginId: 'p', id: 'b', title: 'Two');
      library.queue.addAll([a, b]);
      await library.remember(b);
      final service = MusicService(library: library);
      final music = MusicSession(
        library: library,
        service: service,
        audio: audio,
      );
      try {
        await music.resume();
        expect(audio.restarted, false);
        expect(audio.requested, 1);
        expect(music.queue.map((t) => t.id), ['a', 'b']);
      } finally {
        music.dispose();
        audio.dispose();
        service.dispose();
        await library.save();
        library.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('music queue uses the existing audio owner, keeps IDs, loads URLs lazily and yields to books', () async {
    final root = await Directory.systemTemp.createTemp('lume-music-session-');
    final library = MusicLibrary(directory: root), audio = _Audio();
    final service = MusicService(library: library);
    final music = MusicSession(
      audio: audio,
      service: service,
      library: library,
    );
    const tracks = [
      MusicTrack(pluginId: 'one', id: 'same', title: 'One', artist: 'Artist'),
      MusicTrack(pluginId: 'two', id: 'same', title: 'Two'),
    ];
    try {
      final pending = music.play(tracks, index: 1);
      await audio.entered.future;
      expect(music.opening, true);
      expect(music.current?.title, 'Two');
      expect(audio.tracks.every((track) => track.music), true);
      expect(audio.tracks.first.artist, 'Artist');
      expect(audio.tracks.map((track) => track.id).toSet(), hasLength(2));
      expect(
        audio.tracks.every(
          (track) => track.initialMedia == null && track.resolve != null,
        ),
        true,
      );
      audio.ready.complete();
      await pending;
      expect(music.opening, false);
      await music.previous();
      expect(music.current?.title, 'One');
      await music.next();
      expect(music.current?.title, 'Two');
      final restored = MusicLibrary(directory: root);
      await restored.load();
      expect(
        restored.queue.map((track) => track.key),
        tracks.map((track) => track.key),
      );
      restored.dispose();
      audio.resource = const MediaResource(
        id: 'book',
        title: 'Book',
        kind: ResourceKind.audioBook,
        destination: Section.video,
        episodes: [],
      );
      audio.notifyListeners();
      expect(music.current, isNull);
      expect(MusicSession.visible.value, false);
    } finally {
      music.dispose();
      audio.dispose();
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      await library.save();
      library.dispose();
      MusicSession.visible.value = false;
      await root.delete(recursive: true);
    }
  });
}
