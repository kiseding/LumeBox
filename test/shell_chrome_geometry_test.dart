import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import 'support/fake_source_manager.dart';

/// 顶栏 / 底栏的纵向位置（用户口径）：
/// 1. 顶部导航（标题 + 图标 + 页签）整条贴近状态栏，只留一小段安全边距——
///    不许「往下陷」；
/// 2. 底部 Dock 悬浮在 iOS 安全区上方 8pt（完整避开底部横条）；
/// 3. 两端移动之后，中间内容区自动撑开占满剩余空间；
/// 4. 只移动容器，不缩放控件——图标按钮仍是 42 的触达尺寸。
///
/// 设备取 1320×2868@3x（440×956pt，刘海机 59 / 34），与真机反馈的机型一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 440.0;
  const height = 956.0;
  const statusInset = 59.0;
  const bottomInset = 34.0;

  late Directory root;
  late ShellDockController controller;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_chrome');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    LumeJsEngine.debugSupportedOverride = true;
    controller = ShellDockController();
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    controller.dispose();
    LumeJsEngine.debugSupportedOverride = null;
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        navigatorObservers: <NavigatorObserver>[ShellDockObserver(controller)],
        home: AppShell(controller: controller, desktopRail: false),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Dock 胶囊本体（Dock 的 key 挂在外层容器上，量它量不到圆角条）。
  Finder dockCapsule() => find
      .descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.byType(ClipRRect),
      )
      .first;

  /// 挂一个**真实板块页**（视频：标题 + 右上角图标 + 书架/探索页签）。
  Future<void> pumpBoard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: VideoPage(
          catalog: const _NoKernelCatalog(),
          sourceManager: FakeSourceManager(
            sources: const <SourceDescriptor>[
              SourceDescriptor(
                id: 'a',
                name: '示例源',
                version: '1.0',
                enabled: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder homePanel() => find
      .ancestor(of: find.byTooltip('播放历史'), matching: find.byType(GlassPanel))
      .first;
  testWidgets('首页标题、操作与源选择合为一个紧凑模块并避让状态栏', (tester) async {
    await pumpBoard(tester);
    expect(find.byType(AppBar), findsNothing);
    final panel = tester.getRect(homePanel());
    expect(panel.top, closeTo(trimmedTopInset(statusInset), 1));
    expect(panel.height, lessThan(160));
    final title = tester.getRect(find.text('视频'));
    final source = tester.getRect(find.text('示例源'));
    expect(source.top, greaterThan(title.bottom));
    expect(source.bottom, lessThan(panel.bottom));
    expect(find.byType(TabBar), findsNothing);
  });
  testWidgets('合并顶部保持至少32点图标触达尺寸', (tester) async {
    await pumpBoard(tester);
    for (final button
        in find
            .descendant(of: homePanel(), matching: find.byType(IconButton))
            .evaluate()) {
      final rect = tester.getRect(find.byWidget(button.widget));
      expect(rect.width, greaterThanOrEqualTo(32));
      expect(rect.height, greaterThanOrEqualTo(32));
      expect(rect.top, greaterThanOrEqualTo(trimmedTopInset(statusInset)));
    }
  });

  testWidgets('底部 Dock 悬浮在屏幕底边之上 + 左右宽度（用户口径第十二次）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 用户口径第七次：**保留一小段悬浮留白**——上一版怼死屏幕底边「改过头了」。
    // 本轮（第十三次）：留白 8 → 4，往下沉、更贴近 Home Indicator，但仍不贴死。
    final gap = height - capsule.bottom;
    expect(
      gap,
      closeTo(bottomInset + 4, 0.01),
      reason: '胶囊要悬浮在安全区之上 4pt（实测 $gap）',
    );
    // 用户口径第十三次：左右再收窄——外边距 16 → 24，两侧留出明显的空白。
    expect(capsule.width, closeTo(width - 48, 0.01), reason: '胶囊按屏宽减左右各 24 摆放');
    expect(capsule.left, closeTo(24, 0.01), reason: '胶囊居中：左侧留白 24');
    // 加宽是**稍微**：两侧仍要留白（不铺满屏宽）。
    expect(capsule.left, greaterThan(0));
    expect(width - capsule.right, closeTo(capsule.left, 0.01));

    // 收窄容器**不许收窄点击区域**：五项平分之后每项仍要够手指点（≥44）。
    final items = find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.byType(InkWell),
        )
        .evaluate()
        .toList();
    expect(items, isNotEmpty);
    for (final element in items) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(
        rect.width,
        greaterThanOrEqualTo(44.0),
        reason: '收窄胶囊后每项只剩 ${rect.width} 宽，点不到',
      );
      expect(
        rect.height,
        greaterThanOrEqualTo(44.0),
        reason: '每项高度 ${rect.height} 太小，容易误触',
      );
    }

    // 而**里面的内容**要避开手势条：图标与文字整体上缩一档；
    // 「内容离屏幕底边」的总净空固定 20（外框留白 + 内部避让）。
    const inset = 20.0;
    final item = tester.getRect(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.novel.label),
          )
          .first,
    );
    expect(
      height - item.bottom,
      greaterThanOrEqualTo(inset),
      reason:
          '胶囊里的文字要避开系统手势条（至少离底边 ${inset}pt，'
          '实测 ${height - item.bottom}）',
    );

    // 图标与文字间距 4，整体在 60 高的内容条里严格垂直居中。
    final novelLabel = find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.text(Section.novel.label),
        )
        .first;
    final novelItem = find
        .ancestor(of: novelLabel, matching: find.byType(InkWell))
        .first;
    final chip = tester.getRect(
      find.descendant(of: novelItem, matching: find.byType(DecoratedBox)).first,
    );
    final label = tester.getRect(novelLabel);
    expect(label.top - chip.bottom, closeTo(4, 0.6), reason: '图标与文字间距 4px');
    expect(
      (chip.top + label.bottom) / 2,
      closeTo(tester.getRect(novelItem).center.dy, 1.5),
      reason: '图标 + 文字整体垂直居中',
    );
  });

  testWidgets('横屏安全区：胶囊避开左右刘海并保持居中', (tester) async {
    await pumpShell(tester);
    tester.view.physicalSize = const Size(956 * 3, 440 * 3);
    tester.view.viewPadding = const FakeViewPadding(
      left: 59 * 3,
      right: 59 * 3,
      bottom: 21 * 3,
    );
    tester.view.padding = const FakeViewPadding(
      left: 59 * 3,
      right: 59 * 3,
      bottom: 21 * 3,
    );
    await tester.pumpAndSettle();
    final capsule = tester.getRect(dockCapsule());
    expect(capsule.left, closeTo(59 + 24, 0.01));
    expect(956 - capsule.right, closeTo(59 + 24, 0.01));
    expect(440 - capsule.bottom, closeTo(21 + 4, 0.01));
    expect(capsule.height, closeTo(54, 0.01));
  });

  testWidgets('键盘弹出时隐藏胶囊且取消列表底部导航避让', (tester) async {
    await pumpShell(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320 * 3);
    tester.view.padding = const FakeViewPadding(top: statusInset * 3);
    await tester.pumpAndSettle();
    expect(tester.getRect(dockCapsule()).top, greaterThan(height));
    final dockContext = tester.element(find.byKey(AppShell.dockKey));
    expect(ShellDockScope.bottomInset(dockContext), 0);
    tester.view.viewInsets = const FakeViewPadding();
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    await tester.pumpAndSettle();
    expect(
      height - tester.getRect(dockCapsule()).bottom,
      closeTo(bottomInset + 4, 0.01),
    );
  });

  testWidgets('切换页签时选中底座走 250ms 果冻过渡（不是硬闪）', (tester) async {
    await pumpShell(tester);

    Finder chipOf(String label) => find
        .descendant(
          of: find
              .ancestor(
                of: find
                    .descendant(
                      of: find.byKey(AppShell.dockKey),
                      matching: find.text(label),
                    )
                    .first,
                matching: find.byType(InkWell),
              )
              .first,
          matching: find.byType(DecoratedBox),
        )
        .first;

    // 未选中时底座仍在树上，只是缩到 0.72 并透明——这样切换时才有过渡可走。
    final before = tester.getRect(chipOf(Section.comic.label));
    final opacity = tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: chipOf(Section.comic.label),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    expect(opacity.opacity, 0);
    expect(opacity.duration, const Duration(milliseconds: 250));

    await tester.tap(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.comic.label),
          )
          .first,
    );
    await tester.pump();
    // 前 50ms：底座从 0.72 倍往满尺寸长，明显不是一格跳到 40。
    await tester.pump(const Duration(milliseconds: 50));
    final growing = tester.getRect(chipOf(Section.comic.label));
    expect(growing.width, greaterThan(before.width));
    expect(growing.width, lessThan(40));

    // 约 100ms：easeOutBack 的过冲把底座推到满尺寸之外再回弹——这就是果冻感。
    await tester.pump(const Duration(milliseconds: 50));
    final bounce = tester.getRect(chipOf(Section.comic.label));
    expect(bounce.width, greaterThan(40), reason: 'easeOutBack 要轻微过冲');

    await tester.pumpAndSettle();
    final after = tester.getRect(chipOf(Section.comic.label));
    expect(after.width, closeTo(40, 0.01));
    expect(after.height, closeTo(22, 0.01));

    // 退场的那一项同步收掉，不残留一块底色。
    final outgoing = tester.getRect(chipOf(Section.novel.label));
    expect(outgoing.width, closeTo(40 * 0.72, 0.01));
  });

  testWidgets('底栏容器更薄 + 圆角椭圆（只收容器，图标文字尺寸不变）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 内容条 64 → 56 → 60 → **54**（第十三次：再收上下内边距，容器更扁平）。
    // 注意这不是胶囊外框的高：外框还要把手势条避让那一段一起画上。
    final item = tester.getRect(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(item.height, closeTo(54, 0.01), reason: '内容条保持统一高度');
    expect(item.height, greaterThanOrEqualTo(44.0), reason: '别压到里面的控件');

    final radius = tester.widget<ClipRRect>(dockCapsule()).borderRadius;
    expect(
      radius,
      BorderRadius.circular(capsule.height / 2),
      reason: '外框要是胶囊 / 椭圆：半径 = 容器高度的一半',
    );

    // 控件尺寸一如既往：选中态的图标与文字都没被缩放。
    final icon = tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(icon.size, 20, reason: '底栏图标尺寸不许随容器收窄而变小');
    final label = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.text(Section.novel.label),
          )
          .first,
    );
    expect(label.style?.fontSize, 12, reason: '全局文字加大一号，底栏容器尺寸保持原样');
  });

  testWidgets('二级页（push 出来的）不留底部白条：内容一路铺到屏幕底边', (tester) async {
    tester.view.physicalSize = const Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewPadding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    tester.view.padding = const FakeViewPadding(
      top: statusInset * 3,
      bottom: bottomInset * 3,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _SecondaryGlassPage(),
                  ),
                ),
                child: const Text('打开二级页'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开二级页'));
    await tester.pumpAndSettle();

    // 用户口径：排行榜这类二级页底部不该多出一条浅色留白。
    // 真因：GlassScaffold 无条件让出底部安全区——壳里那一段正好被悬浮 Dock 盖住
    // （看不见，也是「最后一行不被 Dock 挡住」的实现），二级页底下没有 Dock，
    // 同一段就成了白条。现在只在壳里让（见 shared/widgets/glass_card.dart）。
    final list = tester.getRect(find.byKey(_SecondaryGlassPage.listKey));
    expect(
      list.bottom,
      closeTo(height, 1),
      reason: '二级页的内容要铺到屏幕底边，实测 ${list.bottom}（屏高 $height）',
    );
  });

  testWidgets('壳里的底部安全区仍然让出：宽度正好是 Dock 的脚印（所以看不见）', (tester) async {
    await pumpShell(tester);

    final capsule = tester.getRect(dockCapsule());
    // 量**壳内容区**（页面骨架）拿到的底部内边距：它在壳 Scaffold 的 body 之内，
    // 那里 Flutter 已经把 padding.bottom 换成了「底栏总高」。这一段必须正好等于
    // 悬浮胶囊占的那一段——等于才是「被胶囊盖住、看不见」，不等于就会露白条，
    // 或者让最后一行压到 Dock 底下。
    final pageContext = tester.element(find.byType(GlassScaffold).first);
    final reserved = MediaQuery.paddingOf(pageContext).bottom;
    final dockBand = height - capsule.top;
    expect(
      reserved,
      closeTo(dockBand, 0.01),
      reason:
          '壳里让出的底部安全区（$reserved）必须等于 Dock 占的那一段'
          '（胶囊上沿到屏幕底边 = $dockBand）',
    );
    expect(reserved, greaterThan(bottomInset), reason: '壳里让的是 Dock 脚印，不是系统手势条');
  });

  testWidgets('顶栏容器下沿两个大圆角（贴屏幕顶端的那两个角保持直角）', (tester) async {
    await pumpBoard(tester);

    final clip = tester.widget<ClipRRect>(
      find.descendant(of: homePanel(), matching: find.byType(ClipRRect)).first,
    );
    final radius = clip.borderRadius as BorderRadius;
    expect(radius.topLeft.x, 24, reason: '首页顶栏为悬浮胶囊');
    expect(radius.topRight.x, 24);
    expect(
      radius.bottomLeft.x,
      greaterThanOrEqualTo(16.0),
      reason: '用户口径要「大圆角」：下沿两角至少 16',
    );
    expect(radius.bottomRight, radius.bottomLeft);
  });

  testWidgets('中间内容区自动撑开：页签内容占满顶栏与 Dock 之间的空间', (tester) async {
    await pumpBoard(tester);

    final appBar = tester.getRect(find.text('视频'));
    // 板块页是「内容铺满整屏、顶栏浮在其上」（behindBar）——因此内容区的上下边界
    // 就是屏幕本身：两端移动后中间这块自动变大，不会再被夹出一条死白。
    final content = tester.getRect(find.byType(ExploreView));
    expect(content.top, closeTo(0, 1), reason: '内容铺满整屏（顶栏浮在其上）');
    expect(
      content.bottom,
      closeTo(height, 1),
      reason:
          '内容一路铺到屏幕底边（本用例把板块页单独挂载，树里没有 Dock 壳，'
          '按二级页口径不让底部安全区，实测 ${content.bottom}）',
    );
    // 顶栏下沿到第一条内容（图源条）之间只隔一档常规间距，不是一整条空白。
    final firstRow = tester.getRect(find.text('示例源'));
    final gap = firstRow.top - appBar.bottom;
    expect(gap, greaterThanOrEqualTo(0.0), reason: '图源条不该被顶栏压住（gap=$gap）');
    // 31pt = 列表 12 的顶部内边距 + 源选择卡片自己的内边距 + 文字基线：
    // 都是一档常规间距，不是「一整条空白」（以前这里会出现半个栏高）。
    expect(gap, lessThanOrEqualTo(36.0), reason: '顶栏与第一条内容之间只该留常规间距（实测 $gap）');
  });
}

/// 一个最小的「二级页」：玻璃骨架 + 可量的滚动视图（量它铺到哪儿）。
class _SecondaryGlassPage extends StatelessWidget {
  const _SecondaryGlassPage();

  static const Key listKey = Key('secondary-list');

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      behindBar: true,
      title: '二级页',
      child: ListView(
        key: listKey,
        padding: GlassScaffold.barInset(context)
            .add(const EdgeInsets.fromLTRB(16, 12, 16, 24)),
        children: const <Widget>[SizedBox(height: 2000, child: Text('内容'))],
      ),
    );
  }
}

/// 三套内核都不可用（本用例只看布局）。
class _NoKernelCatalog implements PlayerKernelCatalog {
  const _NoKernelCatalog();

  @override
  bool isAvailable(PlayerKernel kernel) => false;

  @override
  String? unavailableReason(PlayerKernel kernel) => '${kernel.label} 未接入';
}
