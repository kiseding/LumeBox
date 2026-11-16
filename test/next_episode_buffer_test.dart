import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/next_episode_buffer.dart';
import 'package:lume_box/features/video/video_play_target.dart';

import 'support/fake_reading_source.dart';

class _Source extends FakeReadingDataSource {
  _Source() : super(section: Section.video);
  int reads = 0, catalogs = 0, failures = 0;
  Completer<ChapterContent?>? pending;
  @override
  Future<List<SourceChapter>> chapters(String itemId) async {
    catalogs++;
    return const [
      SourceChapter(id: 'c1', title: '1'),
      SourceChapter(id: 'c2', title: '2'),
    ];
  }

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    reads++;
    if (failures-- > 0) throw StateError('暂时不可用');
    if (pending != null) return pending!.future;
    return VideoContent(url: Uri.parse('https://example.test/$chapterId.mp4'));
  }
}

class _Player extends AbstractPlayer {
  final state = ValueNotifier(const PlayerSnapshot());
  final info = ValueNotifier(const PlayerStats());
  int loads = 0, disposals = 0;
  Completer<void>? pending;
  @override
  ValueListenable<PlayerSnapshot> get snapshot => state;
  @override
  ValueListenable<PlayerStats> get stats => info;
  @override
  Future<void> load(PlayerMedia media) async {
    loads++;
    if (pending != null) await pending!.future;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> applySettings(PlayerSettings settings) async {}
  @override
  Widget buildView() => const SizedBox();
  @override
  Future<void> dispose() async {
    disposals++;
    state.dispose();
    info.dispose();
  }
}

void main() {
  const target = VideoPlayTarget(
    sourceId: 'source',
    itemId: 'book',
    title: '书',
    chapterIndex: 0,
    chapterId: 'c1',
    chapterTitle: '1',
  );
  const settings = PlayerSettings();
  setUp(() => MediaPreload.instance.video = true);
  test('目录预热后区分末集，清理后不复用旧目录数量', () async {
    final source = _Source(), buffer = NextEpisodeBuffer();
    addTearDown(buffer.dispose);
    expect(buffer.hasNext(target), isNull);
    await buffer.warmCatalog(target, () async => source);
    expect(buffer.hasNext(target), isTrue);
    const last = VideoPlayTarget(
      sourceId: 'source',
      itemId: 'book',
      title: '书',
      chapterIndex: 1,
      chapterId: 'c2',
      chapterTitle: '2',
    );
    expect(buffer.hasNext(last), isNull);
    await buffer.warmCatalog(last, () async => source);
    expect(buffer.hasNext(last), isFalse);
    await buffer.clear();
    expect(buffer.hasNext(last), isNull);
  });
  test(
    'prepared player exposes its actual media and rejects a late error',
    () async {
      final source = _Source(), player = _Player();
      final buffer = NextEpisodeBuffer();
      await buffer.prepare(target, settings, () async => source, (_) => player);
      final ready = buffer.take(target, 1, settings.kernel)!;
      expect(ready.media?.uri, Uri.parse('https://example.test/c2.mp4'));
      await player.dispose();
      final failed = _Player();
      await buffer.prepare(target, settings, () async => source, (_) => failed);
      failed.state.value = const PlayerSnapshot(error: 'expired address');
      expect(buffer.take(target, 1, settings.kernel), isNull);
      await buffer.clear();
      expect(failed.disposals, 1);
      buffer.dispose();
    },
  );
  test(
    'catalog warmup performs no content fetch or player allocation',
    () async {
      final source = _Source(), player = _Player();
      final buffer = NextEpisodeBuffer();
      await buffer.warmCatalog(target, () async => source);
      await buffer.warmCatalog(target, () async => source);
      expect(source.catalogs, 1);
      expect(source.reads, 0);
      await buffer.prepare(target, settings, () async => source, (_) => player);
      expect(source.catalogs, 1);
      expect(source.reads, 1);
      expect(buffer.take(target, 1, settings.kernel)?.player, same(player));
      buffer.dispose();
      await player.dispose();
    },
  );
  test(
    'failed speculative preparation has a cooldown and at most two attempts',
    () async {
      var now = DateTime(2026);
      final source = _Source()..failures = 10;
      final buffer = NextEpisodeBuffer(now: () => now);
      Future<void> prepare() => buffer.prepare(
        target,
        settings,
        () async => source,
        (_) => _Player(),
      );
      await prepare();
      await prepare();
      expect(source.reads, 1);
      now = now.add(const Duration(seconds: 11));
      await prepare();
      now = now.add(const Duration(seconds: 11));
      await prepare();
      expect(source.reads, 2);
      buffer.dispose();
    },
  );
  testWidgets(
    'slow next episode remains available for adoption after eight seconds',
    (tester) async {
      final source = _Source();
      final player = _Player()..pending = Completer<void>();
      final buffer = NextEpisodeBuffer();
      final task = buffer.prepare(
        target,
        settings,
        () async => source,
        (_) => player,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(player.disposals, 0);
      player.pending!.complete();
      await tester.pump();
      await task;
      expect(buffer.take(target, 1, settings.kernel)?.player, same(player));
      buffer.dispose();
      await player.dispose();
    },
  );

  test('clearing disposes an in-flight native preload exactly once', () async {
    final source = _Source();
    final player = _Player()..pending = Completer<void>();
    final buffer = NextEpisodeBuffer();
    final task = buffer.prepare(
      target,
      settings,
      () async => source,
      (_) => player,
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.loads, 1);
    await buffer.clear();
    expect(player.disposals, 1);
    player.pending!.complete();
    await task;
    expect(player.disposals, 1);
    buffer.dispose();
  });

  test('manual switch shares in-flight parsing instead of canceling and starting again', () async {
    final source = _Source()..pending = Completer<ChapterContent?>();
    final buffer = NextEpisodeBuffer();
    final task = buffer.prepare(
      target,
      settings,
      () async => source,
      (_) => _Player(),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      await buffer.takeWhenReady(
        target,
        1,
        settings.kernel,
        wait: const Duration(milliseconds: 10),
      ),
      isNull,
    );
    final resolved = buffer.resolvedWhenReady(target, 1, settings.kernel);
    source.pending!.complete(
      VideoContent(url: Uri.parse('https://example.test/c2.mp4')),
    );
    expect((await resolved)?.chapter.id, 'c2');
    await task;
    expect(source.reads, 1);
    buffer.dispose();
  });
  test('resolved content survives a slow native load and clear unblocks the next generation', () async {
    final source = _Source();
    final slow = _Player()..pending = Completer<void>();
    final buffer = NextEpisodeBuffer();
    final pending = buffer.prepare(
      target,
      settings,
      () async => source,
      (_) => slow,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      await buffer.takeWhenReady(
        target,
        1,
        settings.kernel,
        wait: const Duration(milliseconds: 1),
      ),
      isNull,
    );
    expect(slow.disposals, 0);
    expect(
      (await buffer.resolvedWhenReady(target, 1, settings.kernel))?.index,
      1,
    );
    expect(source.reads, 1);
    await buffer.clear();
    final fresh = _Player();
    await buffer.prepare(target, settings, () async => source, (_) => fresh);
    slow.pending!.complete();
    await pending;
    expect(buffer.take(target, 1, settings.kernel)?.player, same(fresh));
    expect(slow.disposals, 1);
    await fresh.dispose();
    buffer.dispose();
  });
}
