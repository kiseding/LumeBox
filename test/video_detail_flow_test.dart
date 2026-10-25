import 'package:lume_box/core/intro/intro_store.dart';
import 'package:lume_box/core/media/media_library.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lume_box/shared/widgets/source_translation.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
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
import 'package:lume_box/features/video/video_play_target.dart';
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

class MultiLineDetailSource extends DetailSource {
  @override
  Future<List<SourceChapter>> chapters(String id) async => const [
    SourceChapter(id: 'a1', title: '第1集', line: '线路A'),
    SourceChapter(id: 'a2', title: '第2集', line: '线路A'),
    SourceChapter(id: 'b1', title: '线路B · 第1集'),
    SourceChapter(id: 'b2', title: '线路B · 第2集'),
  ];
}

class LongDetailSource extends DetailSource {
  @override
  Future<List<SourceChapter>> chapters(String id) async => [
    for (var i = 1; i <= 230; i++) SourceChapter(id: 'e$i', title: '第$i集'),
  ];
}

class RoutePlayer extends AbstractPlayer {
  final state = ValueNotifier(const PlayerSnapshot());
  final information = ValueNotifier(const PlayerStats());
  PlayerMedia? media;
  final seeks = <Duration>[];
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
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

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
    await IntroStore.open();
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
    await IntroStore.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  testWidgets('线路切换不预解析，数字选集只播放所选线路并保持索引', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = MultiLineDetailSource();
    VideoPlayTarget? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, target, _, _) async => opened = target,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('播放线路'), findsOneWidget);
    expect(
      tester
          .widget<SourceText>(
            find.descendant(
              of: find.byKey(const Key('video-detail-summary')),
              matching: find.byType(SourceText),
            ),
          )
          .maxLines,
      2,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('video-detail-summary'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('video-detail-play'))).dy,
      ),
    );
    expect(find.text('线路A · 2 集'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('video-detail-play'))).width,
      closeTo((440 - 32) * .72, 2),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('video-detail-quick-actions'))).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byKey(const Key('video-detail-play'))).dy,
      ),
    );
    expect(find.byKey(const Key('video-detail-recommendations')), findsNothing);
    expect(source.parses, 0);
    await tester.ensureVisible(find.text('线路A · 2 集'));
    await tester.tap(find.text('线路A · 2 集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路B · 2 集').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-detail-style')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('紧凑版（当前版）'));
    await tester.tap(
      find.ancestor(
        of: find.text('紧凑版（当前版）'),
        matching: find.byType(CheckedPopupMenuItem<bool>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('线路B · 2 集'), findsOneWidget, reason: '两版共享线路选择');
    expect(
      find.byKey(const Key('video-detail-tmdb-status')),
      findsNothing,
      reason: '未匹配时不显示资料图标',
    );
    expect(find.byKey(const Key('video-detail-metadata-row')), findsOneWidget);
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    state.tmdb.metadata = const TmdbMetadata(
      overview: '',
      posters: [],
      cast: ['示例演员'],
      recommendations: [TmdbRecommendation(title: '推荐示例', poster: '')],
    );
    state.tmdb.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-detail-tmdb-status')), findsOneWidget);
    expect(find.text('示例演员'), findsOneWidget);
    expect(find.text('相似影片 · 全站找片'), findsOneWidget);
    expect(find.text('推荐示例'), findsOneWidget);
    expect(source.parses, 0);
    final second = find.byKey(const ValueKey('video-detail-episode-1'));
    await tester.ensureVisible(second);
    await tester.runAsync(() async {
      await tester.tap(second);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(opened?.chapterId, 'b2');
    expect(opened?.chapterIndex, 1);
    expect(opened?.chapterTitle, '第2集');
    expect(source.parses, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏空演员和重复入口，保留布局与逐集续播，缺集不自动换线', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    library.setSetting('video.detail.originalStyle', 'false');
    library.saveProgress(
      VideoProgress(
        section: Section.video,
        itemId: 'movie',
        chapterIndex: 1,
        chapterId: 'a2',
        chapterTitle: '第2集',
        updatedAt: DateTime.now(),
        position: const Duration(minutes: 12, seconds: 36),
        duration: const Duration(minutes: 40),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: MultiLineDetailSource(),
          item: const SourceItem(id: 'movie', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(VideoDetailPage));
    expect(state.originalStyle, false);
    expect(find.text('继续看 · 第2集'), findsOneWidget);
    expect(find.text('看到 12:36 / 40:00'), findsOneWidget);
    expect(find.text('演员'), findsNothing);
    expect(find.text('全部'), findsNothing);
    expect(find.text('追番'), findsNothing);
    expect(
      find.byKey(const ValueKey('video-episode-progress-1')),
      findsOneWidget,
    );
    state.lines['缺集线路'] = [const SourceChapter(id: 'c3', title: '第3集')];
    expect(state.changeLine('缺集线路'), false);
    await tester.pumpAndSettle();
    expect(state.currentLine, '线路A');
    expect(state.selected, 1);
    expect(find.text('该线路没有对应集，请在选集里手动选择'), findsOneWidget);
    expect(state.changeLine('线路B'), true);
    await tester.pumpAndSettle();
    expect(find.text('继续看 · 第2集'), findsOneWidget);
    expect(state.lineResume.position, const Duration(minutes: 12, seconds: 36));
  });

  testWidgets('长剧集数字跳转只定位不播放，清除定位后恢复完整列表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = LongDetailSource();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailPage(
          source: source,
          item: const SourceItem(id: 'long', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('video-detail-select-episodes')),
    );
    await tester.tap(find.byKey(const Key('video-detail-select-episodes')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('video-episode-jump')), '203');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-202')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-0')),
      findsNothing,
    );
    expect(source.parses, 0);
    await tester.tap(find.text('显示全部剧集'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放器报错换线路仍播放同一集并恢复时间点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = MultiLineDetailSource();
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
    final player = RoutePlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerPage(
          library: library,
          sourceManager: manager,
          playerFactory: (_) => player,
          catalog: const RouteCatalog(),
          media: PlayerMedia(uri: Uri.parse('https://example.test/a2.mp4')),
          target: VideoPlayTarget(
            sourceId: source.id,
            itemId: 'movie',
            title: '详情测试片',
            chapterIndex: 1,
            chapterId: 'a2',
            chapterTitle: '第2集',
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    player.state.value = const PlayerSnapshot(
      error: 'fixture连接失败',
      position: Duration(seconds: 75),
      duration: Duration(minutes: 40),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('换线路继续看'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路B'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(player.media!.uri.path, '/b2.mp4');
    expect(player.seeks, contains(const Duration(seconds: 75)));
    expect(source.parses, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('窄屏大字长剧集分页显示，选集弹层不一次构建全部按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: VideoDetailPage(
          source: LongDetailSource(),
          item: const SourceItem(id: 'long', title: '详情测试片'),
          library: library,
          onPlay: (_, _, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-detail-style')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('紧凑版（当前版）'));
    await tester.tap(
      find.ancestor(
        of: find.text('紧凑版（当前版）'),
        matching: find.byType(CheckedPopupMenuItem<bool>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OutlinedButton).evaluate().length, lessThan(55));
    expect(
      find.byKey(const ValueKey('video-detail-episode-49')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('video-detail-episode-50')), findsNothing);
    final picker = find.byKey(const Key('video-detail-select-episodes'));
    await Scrollable.ensureVisible(tester.element(picker), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('video-detail-picker-episode-50')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
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
      const Color(0xff55516e),
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
