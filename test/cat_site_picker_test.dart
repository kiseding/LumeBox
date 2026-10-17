import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/shared/widgets/cat_site_tile.dart';
import 'package:lume_box/shared/widgets/source_icon.dart';

/// 猫源「选择站点」面板的专用外观：
/// - 固定 64 高；
/// - 没有左侧字母图标、没有右侧三点；
/// - 文字单行居中，双列再窄也只省略、不折行；
/// - 长按整行拖拽，左滑露出「设置」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final service = CatService.instance;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_cat_picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    for (final section in Section.values) {
      await ReadingLibrary.open(section);
    }
  });

  tearDown(() async {
    service.subscriptions.clear();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    // Windows 上 sqlite / 配置文件的句柄释放偶尔晚于 tearDown；重试几次，
    // 避免临时目录清理失败把已经通过的界面断言判成失败。
    for (var i = 0; i < 5 && root.existsSync(); i++) {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.runAsync(service.boot);
    // 先让板块页按「没有订阅」的稳定状态落地，避免新建订阅触发自动加载，
    // 页面里的转圈会让 pumpAndSettle 一直等下去（与猫源拖拽测试同一顺序）。
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: const CatPage()),
    );
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    service.subscriptions
      ..clear()
      ..add(
        CatSubscription(
          id: 'demo',
          name: '牛二',
          url: 'https://example.test/source',
          automatic: false,
          sites: const <CatSite>[
            CatSite(subscriptionId: 'demo', key: 'a', name: '豆瓣|首页', api: '/a'),
            CatSite(
              subscriptionId: 'demo',
              key: 'b',
              name: '日期:20261017',
              api: '/b',
            ),
            CatSite(subscriptionId: 'demo', key: 'c', name: '配置|中心', api: '/c'),
            CatSite(subscriptionId: 'demo', key: 'd', name: '我的|网盘', api: '/d'),
            CatSite(subscriptionId: 'demo', key: 'e', name: '玩偶|4K', api: '/e'),
            CatSite(subscriptionId: 'demo', key: 'f', name: '多多|4K', api: '/f'),
          ],
        ),
      );
    service.siteColumns = 1;

    await tester.tap(find.byTooltip('源管理'));
    await tester.pumpAndSettle();
  }

  testWidgets('猫源选择面板：16pt 基线、56/64 高、1px 描边、居中与左滑菜单', (tester) async {
    await pumpPicker(tester);

    final tiles = find.byType(CatSiteTile);
    expect(tiles, findsWidgets);

    for (final element in tiles.evaluate()) {
      final tile = find.byWidget(element.widget);
      expect(tester.getSize(tile).height, 56, reason: '单列卡片 56 高');
      final material = tester.widget<Material>(
        find.descendant(of: tile, matching: find.byType(Material)).first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.width, 1, reason: '卡片要有 1px 描边');
      expect(shape.side.color, const Color(0xFFE5E5EA));
      expect(
        find.descendant(of: tile, matching: find.byType(SourceIcon)),
        findsNothing,
        reason: '猫源行不许再有左侧字母图标',
      );
      expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.more_vert)),
        findsNothing,
        reason: '猫源行不许再有右侧三点',
      );
      final text = find.descendant(of: tile, matching: find.byType(Text)).first;
      final widget = tester.widget<Text>(text);
      expect(widget.maxLines, 1);
      expect(widget.overflow, TextOverflow.ellipsis);
      expect(widget.textAlign, TextAlign.center);
      expect(
        tester.getSize(text).height,
        lessThan(20),
        reason: '文字必须保持一行（15pt 行高 1.2 ≈ 18）',
      );
    }

    // 最左侧卡片外边缘必须与「加载或刷新包内站点」的文本左基线对齐。
    final subtitle = find.text('加载或刷新包内站点');
    expect(subtitle, findsOneWidget);
    expect(
      tester.getTopLeft(tiles.first).dx,
      closeTo(tester.getTopLeft(subtitle).dx, .01),
      reason: '卡片不应比上方订阅文字更靠内',
    );

    // 底下的板块页头部也可能显示同一个站点名；所有查找都限定在猫源卡片里。
    Finder tileText(String label) => find
        .descendant(of: find.byType(CatSiteTile), matching: find.text(label))
        .first;

    // 单列：长日期也只占一行。
    final dateText = tileText('日期:20261017');
    expect(tester.getSize(dateText).height, lessThan(20));
    expect(
      tester
          .getSize(
            find
                .ancestor(of: dateText, matching: find.byType(CatSiteTile))
                .first,
          )
          .height,
      56,
      reason: '单列卡片 56 高',
    );

    // 双列：两列同一行，长日期仍然单行。
    await tester.tap(find.text('双列列表'));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(tileText('豆瓣|首页'));
    final second = tester.getTopLeft(dateText);
    expect((first.dy - second.dy).abs(), lessThan(1), reason: '双列应并排');
    expect(tester.getSize(dateText).height, lessThan(20), reason: '双列也不许折行');
    expect(
      tester
          .getSize(
            find
                .ancestor(of: dateText, matching: find.byType(CatSiteTile))
                .first,
          )
          .height,
      64,
      reason: '双列卡片 64 高（约 2.2 宽高比）',
    );

    // 左滑露出菜单；长按拖拽由 SourceDragTile 负责（布局测试另有用例）。
    final firstTile = find
        .ancestor(of: tileText('豆瓣|首页'), matching: find.byType(CatSiteTile))
        .first;
    final before = tester.getTopLeft(firstTile);
    await tester.drag(firstTile, const Offset(-90, 0));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(firstTile);
    expect(after.dx, lessThan(before.dx - 40), reason: '左滑应把卡片推开，露出右侧菜单');
    // 菜单按钮已在树里（每张卡片各一个），左滑后第一张的按钮移到卡片右侧、
    // 成为可见/可点的操作区。
    expect(find.text('设置'), findsWidgets);

    // 让 CatPage 先卸载，释放阅读库句柄；不在这里 pumpAndSettle，
    // 页面退出时可能还有未完成的入场动画/定时器。
    service.subscriptions.clear();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('猫源卡片选中态：1px 淡紫描边', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: CatSiteTile(label: '选中的站点', selected: true, onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(CatSiteTile),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side.width, 1);
    expect(shape.side.color, LumeTheme.accent.withValues(alpha: .55));
  });
}
