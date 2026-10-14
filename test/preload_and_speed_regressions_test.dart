import 'package:lume_box/core/session/section.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/buffering.dart';
import 'package:lume_box/core/player/download_speed.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/player/media_kit_mpv_engine.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/next_episode_buffer.dart';
import 'package:lume_box/features/video/player_hud.dart';
import 'package:lume_box/features/video/player_speed_meter.dart';
import 'package:lume_box/features/video/video_play_target.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('MPV缓存终点扣除播放位置，避免把已播放时间当成前向缓冲', () {
    expect(
      MediaKitMpvEngine.bufferedAhead(
        const Duration(seconds: 11),
        const Duration(seconds: 10),
      ),
      const Duration(seconds: 1),
    );
    expect(
      MediaKitMpvEngine.bufferedAhead(
        const Duration(seconds: 9),
        const Duration(seconds: 10),
      ),
      Duration.zero,
    );
    expect(
      MediaKitMpvEngine.bufferedAhead(null, const Duration(seconds: 10)),
      isNull,
    );
  });
  test('下载计数按采样间隔计算，空闲为0，重置和不可用不产生假读数', () {
    final sampler = DownloadSpeedSampler();
    expect(sampler.sample(1000, Duration.zero), isNull);
    expect(sampler.sample(251000, const Duration(milliseconds: 500)), 500000);
    expect(sampler.sample(251000, const Duration(seconds: 1)), 0);
    expect(sampler.sample(20, const Duration(seconds: 2)), isNull);
    expect(sampler.sample(null, const Duration(seconds: 3)), isNull);
    expect(sampler.sample(1000, const Duration(seconds: 4)), isNull);
    expect(PlaybackSpeedMeter.describeBytes(125000000), '125.0MB/s');
    expect(PlaybackSpeedMeter.describeBytes(0), '0KB/s');
  });
  test('AV统计以playerId读取，通道缺失时留空', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AvNetworkStatistics.channel, (call) async {
          expect(call.method, 'readBytes');
          expect(call.arguments, {'playerId': 7});
          return 125000000;
        });
    expect(await AvNetworkStatistics.readBytes(7), 125000000);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AvNetworkStatistics.channel, null);
    expect(await AvNetworkStatistics.readBytes(7), isNull);
  });
  testWidgets('HUD真实下载优先；额外请求明确标源测速；0不回退成旧测速', (tester) async {
    final stats = ValueNotifier(const PlayerStats(downloadBytesPerSecond: 0));
    final probe = ValueNotifier<int?>(8000);
    addTearDown(stats.dispose);
    addTearDown(probe.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerHud(stats: stats, networkKbps: probe),
      ),
    );
    expect(find.text('网速 0KB/s'), findsOneWidget);
    expect(find.textContaining('源测速'), findsNothing);
    stats.value = const PlayerStats(downloadBytesPerSecond: 125000000);
    await tester.pump();
    expect(find.text('网速 125.0MB/s'), findsOneWidget);
    stats.value = const PlayerStats();
    await tester.pump();
    expect(find.text('源测速 1.0MB/s'), findsOneWidget);
  });

  const target = VideoPlayTarget(
    sourceId: 's',
    itemId: 'film',
    title: '片',
    chapterIndex: 0,
    chapterId: 'e1',
    chapterTitle: '第一集',
  );
  test('下一集保留请求头、限额缓冲、静音暂停，并且只准备一次、接手一次', () async {
    final buffer = NextEpisodeBuffer();
    final source = _Source();
    final player = _Player();
    int creates = 0;
    Future<void> prepare() =>
        buffer.prepare(target, const PlayerSettings(), () async => source, (_) {
          creates++;
          return player;
        });
    await Future.wait([prepare(), prepare()]);
    expect(creates, 1);
    expect(player.media!.headers, {'Referer': 'https://example.com/'});
    expect(player.volume, 0);
    expect(player.plays, 0);
    expect(player.pauses, 1);
    expect(player.buffer!.maxBufferBytes, 8 * 1024 * 1024);
    expect(buffer.take(target, 2, PlayerKernel.avplayer), isNull);
    final ready = buffer.take(target, 1, PlayerKernel.avplayer)!;
    expect(ready.player, same(player));
    expect(ready.chapter.id, 'e2');
    expect(buffer.take(target, 1, PlayerKernel.avplayer), isNull);
    buffer.discard();
    expect(player.disposals, 0, reason: '接手后的播放器由播放页管理');
    await player.dispose();
  });
  test('退出或换源取消在飞预加载，晚到的结果不会被接手且实例被释放', () async {
    final buffer = NextEpisodeBuffer();
    final source = _Source();
    final player = _Player()..loadGate = Completer<void>();
    final task = buffer.prepare(
      target,
      const PlayerSettings(),
      () async => source,
      (_) => player,
    );
    await Future<void>.delayed(Duration.zero);
    buffer.discard();
    player.loadGate!.complete();
    await task;
    expect(buffer.take(target, 1, PlayerKernel.avplayer), isNull);
    expect(player.disposals, 1);
  });
}

class _Source implements DataSource {
  @override
  Section get section => Section.video;
  @override
  String get id => "s";
  @override
  Future<List<SourceChapter>> chapters(String id) async => const [
    SourceChapter(id: 'e1', title: '第一集'),
    SourceChapter(id: 'e2', title: '第二集'),
  ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => VideoContent(
    url: Uri.parse('https://example.com/$chapterId.mp4'),
    headers: const {'Referer': 'https://example.com/'},
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Player extends AbstractPlayer {
  @override
  final ValueNotifier<PlayerSnapshot> snapshot = ValueNotifier(
    const PlayerSnapshot(),
  );
  @override
  final ValueNotifier<PlayerStats> stats = ValueNotifier(const PlayerStats());
  int plays = 0, pauses = 0, disposals = 0;
  double volume = 1;
  PlayerMedia? media;
  BufferingConfig? buffer;
  Completer<void>? loadGate;
  @override
  Future<void> load(PlayerMedia value) async {
    media = value;
    await loadGate?.future;
  }

  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration value) async {}
  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> applySettings(PlayerSettings value) async {}
  @override
  Future<void> setBuffering(BufferingConfig value) async {
    buffer = value;
  }

  @override
  Widget buildView() => const SizedBox();
  @override
  Future<void> dispose() async {
    disposals++;
    snapshot.dispose();
    stats.dispose();
  }
}
