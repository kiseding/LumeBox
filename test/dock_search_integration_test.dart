import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/compact_browse_header.dart';
import 'package:lume_box/features/shell/dock_liquid_surface.dart';
import 'package:lume_box/features/shell/dock_search_button.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/shell/shell_dock_bar.dart';

const entries = [
  ShellDockEntry(
    id: 'comic',
    label: '漫画',
    icon: Icons.auto_stories_outlined,
    selectedIcon: Icons.auto_stories,
  ),
  ShellDockEntry(
    id: 'video',
    label: '视频',
    icon: Icons.play_circle_outline,
    selectedIcon: Icons.play_circle,
  ),
  ShellDockEntry(
    id: 'settings',
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

void main() {
  test('搜索外观持久化往返，旧配置默认一致并限制越界尺寸', () {
    const custom = DockAppearance(
      searchGap: 18,
      searchSize: 1.2,
      searchIconScale: .6,
      searchOpacity: .5,
      searchBlur: 1.4,
      searchLiquid: false,
    );
    expect(DockAppearance.fromJson(custom.toJson()), custom);
    expect(DockAppearance.fromJson({}), DockAppearance.defaults);
    final clamped = DockAppearance.fromJson({
      'searchSize': 99,
      'searchGap': -4,
      'searchOpacity': double.nan,
      'searchBlur': -8,
      'searchIconScale': 999,
    });
    expect(clamped.searchButtonSize, closeTo(54 * 1.3, .001));
    expect(clamped.searchGap, 0);
    expect(clamped.searchOpacity, 1);
    expect(clamped.searchBlur, 0);
    expect(clamped.searchIconScale, .65);
  });

  test('销毁旧页面不清除新页面的搜索回调，控制器销毁后释放安全', () {
    final controller = ShellDockController();
    final oldOwner = Object(), newOwner = Object();
    void current() {}
    controller.registerSearch(oldOwner, () {});
    controller.registerSearch(newOwner, current);
    controller.unregisterSearch(oldOwner);
    expect(controller.searchAction, current);
    controller.dispose();
    controller.unregisterSearch(newOwner);
  });

  testWidgets('搜索由同一个底栏绘制，按压整组联动且回调跟随当前页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 380));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ShellDockController();
    addTearDown(controller.dispose);
    final tapped = <String>[];
    var active = 'comic';
    final boundary = GlobalKey();
    if (Platform.environment['LUME_CAPTURE_PREVIEW'] == '1') {
      await tester.runAsync(() async {
        for (final font in [
          (
            'MaterialIcons',
            'C:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
          ('PreviewChinese', 'C:/Windows/Fonts/msyh.ttc'),
        ]) {
          final loader = FontLoader(font.$1)
            ..addFont(
              Future.value(
                ByteData.sublistView(await File(font.$2).readAsBytes()),
              ),
            );
          await loader.load();
        }
      });
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build().copyWith(
          textTheme: LumeTheme.build().textTheme.apply(
            fontFamily: 'PreviewChinese',
          ),
        ),
        home: StatefulBuilder(
          builder: (context, refresh) => ShellDockScope(
            controller: controller,
            searchInDock: true,
            searchBesideDock: true,
            child: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                extendBody: true,
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xFFB3DAD4),
                              Color(0xFFDBB9DB),
                              Color(0xFF9CBCE0),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                      ),
                    ),
                    const Center(
                      child: Text(
                        'LumeBox',
                        style: TextStyle(
                          fontSize: 32,
                          color: Color(0xFF314456),
                        ),
                      ),
                    ),
                    BrowseSearchButton(onPressed: () => tapped.add(active)),
                  ],
                ),
                bottomNavigationBar: AnimatedBuilder(
                  animation: Listenable.merge([controller, controller.search]),
                  builder: (context, _) => ShellDockBar(
                    entries: entries,
                    activeId: active,
                    onSelect: (id) => refresh(() => active = id),
                    appearance: const DockAppearance(searchGap: 12),
                    showSearch: true,
                    onSearch: controller.searchAction,
                    bottomMargin: 20,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DockSearchButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ShellDockBar),
        matching: find.byTooltip('搜索'),
      ),
      findsOneWidget,
    );
    final search = find.byType(DockSearchButton);
    final pill = find.byKey(ShellDockBar.capsuleSurfaceKey);
    final restingSearch = tester.getRect(search);
    final restingPill = tester.getRect(pill);
    expect(restingSearch.left - restingPill.right, closeTo(12, .01));
    expect(restingSearch.bottom, closeTo(restingPill.bottom, .01));
    final gesture = await tester.startGesture(tester.getCenter(search));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getRect(search).width, greaterThan(restingSearch.width));
    expect(tester.getRect(pill).width, greaterThan(restingPill.width));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tapped, ['comic']);
    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(tapped, ['comic', 'video']);
    if (Platform.environment['LUME_CAPTURE_PREVIEW'] == '1') {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('.dart_tool/diagnostic_review/dock-search-preview.png')
            .writeAsBytes(data!.buffer.asUint8List());
      });
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(controller.searchAction, isNull);
  });

  testWidgets('窄屏大按钮不溢出，搜索材质与图标参数实际应用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ShellDockBar(
              entries: entries,
              activeId: 'comic',
              onSelect: (_) {},
              onSearch: () {},
              showSearch: true,
              appearance: const DockAppearance(
                height: 150,
                horizontalMargin: 100,
                searchSize: 1.3,
                searchGap: 28,
                searchIconScale: .3,
                searchBlur: 0,
                searchOpacity: 0,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<DockSearchButton>(
      find.byType(DockSearchButton),
    );
    expect(button.size, 150);
    final surface = tester.widget<DockLiquidSurface>(
      find.descendant(
        of: find.byType(DockSearchButton),
        matching: find.byType(DockLiquidSurface),
      ),
    );
    expect(surface.blurSigma, 0);
    expect(surface.tintOpacity, 0);
    expect(
      tester.getRect(find.byType(DockSearchButton)).right,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
  });
}
