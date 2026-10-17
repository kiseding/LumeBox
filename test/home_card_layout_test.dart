import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/poster_card.dart';

void main() {
  const item = SourceItem(
    id: 'a',
    title: '仙逆剧场版 弑仙之战',
    subtitle: '评分 8.4 · 蓝光',
    duration: Duration(hours: 2, minutes: 25),
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('首页单列：80×100 封面、简介/时长、三点菜单', (tester) async {
    await pump(
      tester,
      CompactSourceItemTile(
        item: item,
        onTap: () {},
        columns: 1,
        coverWidth: 80,
        coverHeight: 100,
        flat: true,
        showMenu: true,
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('source-tile-cover'))),
      const Size(80, 100),
    );
    expect(find.byKey(const ValueKey('source-tile-menu')), findsOneWidget);
    expect(find.text('评分 8.4 · 蓝光'), findsOneWidget);
    expect(find.text('2:25:00'), findsOneWidget);
  });

  testWidgets('首页双列：60×80 封面、紧凑且不塞三点菜单', (tester) async {
    await pump(
      tester,
      SizedBox(
        width: 174,
        child: CompactSourceItemTile(
          item: item,
          onTap: () {},
          columns: 2,
          coverWidth: 60,
          coverHeight: 80,
          showMenu: false,
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('source-tile-cover'))),
      const Size(60, 80),
    );
    expect(find.byKey(const ValueKey('source-tile-menu')), findsNothing);
    expect(find.text('评分 8.4 · 蓝光'), findsOneWidget);
  });

  testWidgets('首页三列：标题外置卡片不再铺白色底板', (tester) async {
    await pump(
      tester,
      SizedBox(
        width: 112,
        height: 182,
        child: PosterTile(item: item, onTap: () {}),
      ),
    );
    expect(find.byType(PosterTile), findsOneWidget);
    expect(find.byType(CoverThumb), findsOneWidget);
    final card = tester.widget<PosterCard>(find.byType(PosterCard));
    expect(card.footnoteBelow, isTrue, reason: '文字外置且不再铺白色底板');
    expect(find.text('仙逆剧场版 弑仙之战'), findsOneWidget);
  });
}
