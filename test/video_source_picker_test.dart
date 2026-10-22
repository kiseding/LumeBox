import 'package:lume_box/shared/widgets/source_icon.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/source_bar.dart';
import 'package:lume_box/features/source/video_source_picker.dart';
import 'package:lume_box/features/source/video_source_scope.dart';
import 'package:lume_box/core/web/web_home_sources.dart';

import 'support/fake_source_manager.dart';

class _PickerCatService extends CatService {
  _PickerCatService() : super.testing();
  @override
  Future<void> boot() async {}
}

void main() {
  late Directory root;
  late _PickerCatService service;
  late FakeSourceManager manager;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('video-type-picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await ReadingLibrary.open(Section.video);
    await ReadingLibrary.open(Section.cat);
    service = _PickerCatService();
    service.subscriptions.add(
      CatSubscription(
        id: 'pack',
        name: '牛二',
        url: 'https://example.test/index.js.md5',
        sites: const [
          CatSite(
            subscriptionId: 'pack',
            key: 'a',
            name: '猫源测试长名称站点',
            api: '/a',
          ),
          CatSite(subscriptionId: 'pack', key: 'b', name: '另一个站点', api: '/b'),
        ],
      ),
    );
    manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'ordinary',
          name: '普通视频长名称测试',
          version: '1.0',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'disabled',
          name: '停用源',
          version: '1',
          enabled: false,
        ),
      ],
    );
  });
  tearDown(() async {
    service.dispose();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('capture'),
              child: VideoSourcePicker(manager: manager, service: service),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('全部按运行类型分组，不混排 JS、PY 与模块', (tester) async {
    manager.sources.addAll(const [
      SourceDescriptor(
        id: 'py',
        name: 'Python源',
        version: '1',
        enabled: true,
        runtimeKind: 'python',
      ),
      SourceDescriptor(
        id: 'esm',
        name: '模块源',
        version: '1',
        enabled: true,
        runtimeKind: 'module',
      ),
    ]);
    await pump(tester);
    for (final pair in [
      ('ordinary', '普通视频长名称测试'),
      ('python', 'Python源'),
      ('module', '模块源'),
    ]) {
      final group = find.byKey(ValueKey('video-source-group-${pair.$1}'));
      await tester.ensureVisible(group);
      expect(
        find.descendant(of: group, matching: find.text(pair.$2)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: group, matching: find.text('猫源测试长名称站点')),
        findsNothing,
      );
    }
  });

  testWidgets('左滑先露出删除，取消保留，确认才删除且相邻卡片保留', (tester) async {
    manager.sources.add(
      const SourceDescriptor(
        id: 'neighbor',
        name: '相邻源',
        version: '1',
        enabled: true,
      ),
    );
    await pump(tester);
    final tile = find.byKey(const ValueKey('video-picker-swipe-ordinary'));
    Future<void> reveal() async {
      await tester.drag(tile, const Offset(-110, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: tile, matching: find.text('删除')));
      await tester.pumpAndSettle();
    }

    await reveal();
    expect(manager.removed, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    await reveal();
    await tester.tap(find.widgetWithText(TextButton, '删除').last);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(manager.removed, ['ordinary']);
    expect(find.text('普通视频长名称测试'), findsNothing);
    expect(find.text('相邻源'), findsOneWidget);
  });

  testWidgets('猫源删除只移除该站点并记住排除记录', (tester) async {
    await pump(tester);
    final record = service.subscriptions.single;
    final site = record.sites.first;
    service.selectedSiteId = site.id;
    final tile = find.byKey(ValueKey('video-picker-swipe-${site.id}'));
    await tester.ensureVisible(tile);
    await tester.drag(tile, const Offset(-110, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: tile, matching: find.text('删除')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除').last);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(record.sites.single.key, 'b');
    expect(service.selectedSiteId, isNull);
    expect(service.needsSiteSelection, isTrue);
    final restored = CatSubscription.fromJson(record.toJson());
    restored.replaceSites([site, ...restored.sites]);
    expect(restored.sites.single.key, 'b');
    expect(service.subscriptions, hasLength(1));
  });

  testWidgets('顶部分类筛选和搜索包名，不改变已有源选择', (tester) async {
    await pump(tester);
    expect(find.byTooltip('源管理'), findsOneWidget);
    expect(find.text('源订阅'), findsNothing);
    expect(
      tester.getCenter(find.byTooltip('源管理')).dy,
      tester.getCenter(find.byTooltip('添加视频源')).dy,
    );
    expect(
      tester.getCenter(find.byTooltip('源管理')).dx,
      lessThan(tester.getCenter(find.byTooltip('添加视频源')).dx),
    );
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    expect(find.text('牛二'), findsOneWidget);
    expect(find.text('停用源'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('video-source-type-cat')));
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsNothing);
    expect(find.text('猫源测试长名称站点'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '牛二');
    await tester.pumpAndSettle();
    expect(find.text('另一个站点'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的源'), findsOneWidget);
    expect(manager.selectedIds, isEmpty);
  });

  testWidgets('网页源长按排序，搜索过滤后仍保留未显示项位置', (tester) async {
    final store = await WebHomeStore.open();
    for (final id in ['first', 'hidden', 'last']) {
      store.upsert(
        WebHomeSource(
          id: id,
          name: id == 'hidden' ? '别的网页' : '排序$id',
          url: 'https://$id.test',
        ),
      );
    }
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('video-source-type-web')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '排序');
    await tester.pumpAndSettle();
    final from = find.byKey(const ValueKey('web-picker-drag-last'));
    final to = find.byKey(const ValueKey('web-picker-drag-first'));
    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.items.map((row) => row.id), ['last', 'hidden', 'first']);
    expect(find.text('排序last'), findsOneWidget);
  });

  testWidgets('从系统文件选择器导入 HTML，自动命名并保存为本地主页', (tester) async {
    final file = File('${root.path}/live.html');
      file.writeAsStringSync(
      '<!doctype html><html><head><title>直播合集</title></head><body>内容</body></html>',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/file_selector'),
      (call) async {
        expect(call.method, 'openFile');
        expect('${call.arguments}', contains('html'));
        return [file.path];
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        null,
      ),
    );
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('video-source-type-web')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加网页主页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 HTML 文件'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('已选择本地 HTML，将保存到 App 内并启用兼容接口'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = WebHomeStore.instance!.items.single;
    expect(saved.name, '直播合集');
    expect(saved.html, contains('<body>内容</body>'));
    expect(saved.url, isEmpty);
    expect(find.text('本地 HTML · 兼容接口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Python 和模块分类显示真实源，普通分类不混入', (tester) async {
    manager.sources.addAll(const [
      SourceDescriptor(
        id: 'py-one',
        name: 'Python 测试源',
        version: '1',
        enabled: true,
        runtimeKind: 'python',
      ),
      SourceDescriptor(
        id: 'module-one',
        name: '模块测试源',
        version: '1',
        enabled: true,
        runtimeKind: 'module',
      ),
    ]);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('video-source-type-python')));
    await tester.pumpAndSettle();
    expect(find.text('Python 测试源'), findsOneWidget);
    expect(find.text('模块测试源'), findsNothing);
    expect(find.text('普通视频长名称测试'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('video-source-type-module')));
    await tester.pumpAndSettle();
    expect(find.text('模块测试源'), findsOneWidget);
    expect(find.text('Python 测试源'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('video-source-type-ordinary')));
    await tester.pumpAndSettle();
    expect(find.text('普通视频长名称测试'), findsOneWidget);
    expect(find.text('Python 测试源'), findsNothing);
    expect(manager.imported, isEmpty);
  });

  testWidgets('选中猫源返回原站点，调用方继续使用原存储', (tester) async {
    VideoSourceChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<VideoSourceChoice>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      VideoSourcePicker(manager: manager, service: service),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('猫源测试长名称站点'));
    await tester.pumpAndSettle();
    expect(result?.site?.id, service.subscriptions.single.sites.first.id);
    expect(result?.sourceId, isNull);
  });

  testWidgets('视频的单个切源按钮使用统一抽屉', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoSourceScope(
          openPicker: (_) async {
            opened++;
          },
          child: Scaffold(
            body: ReadingSourceBar(
              section: Section.video,
              manager: manager,
              sources: manager.sources,
              currentId: 'ordinary',
              onSelect: (_) {},
              onManage: () {},
              showManage: false,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-source-picker')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('选择视频源'), findsNothing);
  });

  testWidgets('视频源卡片与漫画共用50高、32图标、14留白、8列距和5行距', (tester) async {
    manager.sources.addAll([
      for (final id in ['b', 'c', 'd'])
        SourceDescriptor(id: id, name: '视频源$id', version: '1.0', enabled: true),
    ]);
    await pump(tester, width: 390);
    final a = find.byKey(const ValueKey('video-picker-source-ordinary'));
    final b = find.byKey(const ValueKey('video-picker-source-b'));
    final c = find.byKey(const ValueKey('video-picker-source-c'));
    final first = tester.getRect(a),
        second = tester.getRect(b),
        third = tester.getRect(c);
    expect(first.height, 50);
    expect(first.width, 177);
    expect(first.left, 14);
    expect(second.right, 376);
    expect(second.left - first.right, 8);
    expect(third.top - first.bottom, 5);
    expect(
      tester.getSize(find.descendant(of: a, matching: find.byType(SourceIcon))),
      const Size(32, 32),
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('长名称适配宽度 $width 字号 $scale', (tester) async {
        await pump(tester, width: width, scale: scale);
        expect(tester.takeException(), isNull);
        if (width == 390 && scale == 1) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('build/video-source-layout-light.png');
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
