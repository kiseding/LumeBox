import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/music/music_library.dart';
import 'package:lume_box/core/music/music_models.dart';
import 'package:lume_box/core/music/music_service.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/music/music_page.dart';
import 'package:lume_box/features/shell/shell_dock.dart';

class _DiscoverService extends MusicService {
  _DiscoverService(MusicLibrary library) : super(library: library);
  final pages = <int>[];
  @override
  Future<MusicDiscoveryResult> discover({
    String? pluginId,
    bool refresh = false,
  }) async => const MusicDiscoveryResult(
    sheets: [
      MusicCollection(
        pluginId: 'p',
        id: 'sheet',
        title: '午后歌单',
        subtitle: '测试音源',
      ),
    ],
    hot: [MusicTrack(pluginId: 'p', id: 'hot', title: '热门歌曲示例')],
    fresh: [MusicTrack(pluginId: 'p', id: 'new', title: '新歌示例')],
  );
  @override
  Future<MusicTrackPage> collectionTracks(
    MusicCollection collection, {
    int page = 1,
  }) async {
    pages.add(page);
    return MusicTrackPage([
      MusicTrack(pluginId: 'p', id: 'track-$page', title: '歌单歌曲$page'),
    ], hasMore: page == 1);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lume-music-page-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    await MusicLibrary.instance.load();
  });
  tearDownAll(() async {
    await root.delete(recursive: true);
  });
  testWidgets('底部搜索从音乐源页返回歌曲搜索并聚焦，隐藏页面不接收搜索', (tester) async {
    final controller = ShellDockController();
    addTearDown(controller.dispose);
    var visible = true;
    Widget scene() => MaterialApp(
      home: ShellDockScope(
        controller: controller,
        integratedSearch: true,
        child: TickerMode(
          enabled: visible,
          child: MusicPage(service: _DiscoverService(MusicLibrary.instance)),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(scene());
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('音乐源'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    controller.requestSearch();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    visible = false;
    await tester.pumpWidget(scene());
    await tester.pumpAndSettle();
    controller.requestSearch();
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'discovery opens a real collection route, paginates and updates after disabling a source',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'music-discover-widget-',
      );
      final library = (await tester.runAsync(() async {
        final library = MusicLibrary(directory: directory);
        await library.load();
        return library;
      }))!;
      library.plugins.add(
        const MusicPlugin(
          id: 'p',
          name: '测试音源',
          protocol: MusicProtocol.musicFree,
        ),
      );
      final service = _DiscoverService(library);
      await tester.binding.setSurfaceSize(const Size(320, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: LumeTheme.build(),
            home: MusicPage(library: library, service: service),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      final sheet = find.text('午后歌单');
      await tester.scrollUntilVisible(
        sheet,
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(sheet);
      await tester.pumpAndSettle();
      await tester.tap(sheet);
      await tester.pumpAndSettle();
      expect(find.text('歌单歌曲1'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text('歌单歌曲2'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      expect(service.pages, [1, 2]);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => library.change(library.plugins.single.copyWith(enabled: false)),
      );
      await tester.pumpAndSettle();
      expect(find.text('午后歌单'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
      library.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );

  testWidgets(
    'music tabs, empty states and import dialog survive a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(theme: LumeTheme.build(), home: const MusicPage()),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('让喜欢的音乐，陪你一会儿'), findsOneWidget);
      expect(find.text('精选歌单'), findsOneWidget);
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.text('我的收藏'), findsOneWidget);
      await tester.tap(find.byTooltip('音乐源'));
      await tester.pumpAndSettle();
      expect(find.text('优先音质'), findsOneWidget);
      await tester.tap(find.byTooltip('添加音乐源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('脚本 / 订阅链接'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://example.com/source.js',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('music discovery remains usable at 320px and double text size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const MusicPage(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
