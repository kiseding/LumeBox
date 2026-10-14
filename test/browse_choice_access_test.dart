import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/browse_choice_access.dart';

void main() {
  testWidgets('长分类固定入口、搜索末尾选项与全部重置，不需横向拖动', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => Align(
              alignment: Alignment.topCenter,
              child: BrowseChoiceAccess(
                choices: [
                  for (var i = 0; i < 100; i++)
                    SourceCategory(id: '$i', title: '分类$i'),
                ],
                selectedId: selected,
                onSelected: (id) => set(() => selected = id),
                child: SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < 100; i++)
                        SizedBox(width: 80, child: Text('快捷$i')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('展开全部分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '分类99');
    await tester.pump();
    expect(find.widgetWithText(TextButton, '分类99'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '分类99'));
    await tester.pumpAndSettle();
    expect(selected, '99');
    expect(find.text('分类99'), findsOneWidget);
    await tester.tap(find.byTooltip('展开全部分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(tester.takeException(), isNull);
  });
}
