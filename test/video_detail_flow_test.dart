import 'package:lume_box/core/media/media_library.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/video_detail_page.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

class DetailSource extends FakeReadingDataSource {
  DetailSource() : super(section: Section.video);
  int parses = 0;
  bool failParse = false;
  bool failDetail = false;
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(
    items: [SourceItem(id: 'movie', title: '详情测试片')],
    hasMore: false,
  );
  @override
  Future<SourceDetail?> detail(String id) async {
    if (failDetail) {
      throw const SourceException(SourceErrorKind.callFailed, 'fixture没有详情接口');
    }
    return SourceDetail(id: id, title: '详情测试片', description: '源站原始简介');
  }

  @override
  Future<List<SourceChapter>> chapters(String id) async => const [
    SourceChapter(id: 'e1', title: '第1集'),
    SourceChapter(id: 'e2', title: '第2集'),
  ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    parses++;
    if (failParse) {
      throw const SourceException(SourceErrorKind.network, 'fixture解析失败');
    }
    return VideoContent(
      url: Uri.parse('https://example.test/$chapterId.mp4'),
      headers: const {'Referer': 'https://source.test/watch'},
    );
  }
}

class RoutePlayer extends AbstractPlayer {
  final state = ValueNotifier(const PlayerSnapshot());
  final information = ValueNotifier(const PlayerStats());
  PlayerMedia? media;
  @override
  ValueListenable<PlayerSnapshot> get snapshot => state;
  @override
  ValueListenable<PlayerStats> get stats => information;
  @override
  Future<void> load(PlayerMedia value) async {
    media = value;
  }

  @override
  Future<void> play() async {
    state.value = const PlayerSnapshot(playing: true);
  }

  @override
  Future<void> pause() async {
    state.value = const PlayerSnapshot();
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> applySettings(PlayerSettings value) async {}
  @override
  Widget buildView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose() async {}
}

class RouteCatalog implements PlayerKernelCatalog {
  const RouteCatalog();
  @override
  bool isAvailable(PlayerKernel kernel) => kernel == PlayerKernel.avplayer;
  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : 'fixture unavailable';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  late DetailSource source;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('video-detail');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.video);
    await MediaLibrary.instance.boot();
    library.setSetting(
      VideoPlayerSettingsStore.keyBackgroundSourceValidation,
      'false',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/mediaTracks'),
          (_) async => {'known': true, 'audio': true, 'video': true},
        );
    source = DetailSource();
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  testWidgets('列表先详情，点击选集直接创建一个全屏实例，旋转复用，返回详情', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final players = <RoutePlayer>[];
    final manager = FakeSourceManager(
      sources: [
        SourceDescriptor(
          id: source.id,
          name: source.name,
          version: '1',
          enabled: true,
        ),
      ],
      opened: {source.id: source},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPage(
          library: library,
          sourceManager: manager,
          catalog: const RouteCatalog(),
          playerFactory: (_) {
            final player = RoutePlayer();
            players.add(player);
            return player;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情测试片'));
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.text('源站原始简介'), findsOneWidget);
    expect(players, isEmpty);
    expect(source.parses, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-detail-episode-1')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('video-detail-episode-1')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(source.parses, 1);
    expect(players.length, 1);
    expect(players.single.media?.uri.path, '/e2.mp4');
    expect(
      players.single.media?.headers?['Referer'],
      'https://source.test/watch',
    );
    expect(find.byKey(const Key('fullscreen-controls')), findsOneWidget);
    expect(find.byKey(VideoPlayerPage.controlPanelKey), findsNothing);
    final instance = tester.state(find.byType(VideoPlayerPage));
    players.single.information.value = const PlayerStats(
      width: 1920,
      height: 1080,
    );
    await tester.binding.setSurfaceSize(const Size(900, 400));
    await tester.pumpAndSettle();
    expect(
      identical(instance, tester.state(find.byType(VideoPlayerPage))),
      isTrue,
    );
    expect(players.length, 1);
    expect(source.parses, 1);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('退出全屏'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.byType(VideoPlayerPage), findsNothing);
  });
  testWidgets('源未实现详情接口仍保留剧集和显式播放流程', (tester) async {
    source.failDetail = true;
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {
            opened++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无简介'), findsOneWidget);
    expect(find.byKey(const Key('video-detail-immersive')), findsOneWidget);
    expect(find.byKey(const Key('video-detail-gradient')), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xff151820),
    );
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(source.parses, 0);
    await tester.ensureVisible(find.byKey(const Key('video-detail-play')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('video-detail-play')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(source.parses, 1);
  });
  testWidgets('冷源加载失败也保留详情，不跳转播放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          loadSource: () async => throw const SourceException(
            SourceErrorKind.callFailed,
            'fixture源加载失败',
          ),
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {
            fail('不应打开播放器');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.textContaining('fixture源加载失败'), findsWidgets);
    expect(find.byType(VideoPlayerPage), findsNothing);
  });

  testWidgets('解析失败留在详情并提示，不调用打开播放器回调', (tester) async {
    source.failParse = true;
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {
            opened++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-detail-episode-1')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('video-detail-episode-1')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(source.parses, 1);
    await tester.ensureVisible(find.byKey(const Key('video-detail-play')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('video-detail-play')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.textContaining('解析失败：'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('video-detail-play')))
          .onPressed,
      isNotNull,
    );
  });
}
