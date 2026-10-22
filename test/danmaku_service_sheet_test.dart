import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/danmaku/danmaku_credentials.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/danmaku/danmaku_service_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, String> stored;
  setUp(() {
    stored = {
      'activeId': 'builtin-local',
      'profilesJson': jsonEncode([
        {
          'id': 'builtin-local',
          'type': 'builtin',
          'url': DandanplayCredentials.builtinBase,
        },
        {
          'id': 'official',
          'type': 'official',
          'url': DandanplayCredentials.officialBase,
          'appId': 'saved-app',
          'appSecret': 'saved-secret',
        },
      ]),
    };
    messenger.setMockMethodCallHandler(DanmakuSourcesStore.channel, (
      call,
    ) async {
      if (call.method == 'read') return stored;
      if (call.method == 'write') {
        stored = Map<String, String>.from(call.arguments as Map);
      }
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(DanmakuSourcesStore.channel, null),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDanmakuPanel<void>(
                context: context,
                builder: (_) => const DanmakuServiceSheet(
                  initial: DandanplayCredentials(
                    '',
                    '',
                    baseUrl: DandanplayCredentials.builtinBase,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String value) async {
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    dropdown.onChanged!(value);
    await tester.pumpAndSettle();
  }

  testWidgets('从内置切到官方复用设置凭证，编辑草稿跨服务保留且不串给兼容服务', (tester) async {
    await open(tester);
    await select(tester, DandanplayCredentials.officialBase);
    final id = find.widgetWithText(TextField, 'AppId');
    final secret = find.widgetWithText(TextField, 'AppSecret');
    expect(tester.widget<TextField>(id).controller!.text, 'saved-app');
    expect(tester.widget<TextField>(secret).controller!.text, 'saved-secret');
    await tester.enterText(id, 'edited-app');
    await select(tester, DandanplayCredentials.defaultBase);
    await tester.ensureVisible(find.text('保存并重新加载弹幕'));
    await tester.tap(find.text('保存并重新加载弹幕'));
    await tester.pumpAndSettle();
    final config = await DandanplayCredentials.load();
    expect(config.appId, isEmpty);
    expect(config.appSecret, isEmpty);
    // A second opening starts from builtin again, as in the playback flow.
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await select(tester, DandanplayCredentials.officialBase);
    await tester.enterText(id, 'edited-app');
    await select(tester, DandanplayCredentials.builtinBase);
    await select(tester, DandanplayCredentials.officialBase);
    expect(tester.widget<TextField>(id).controller!.text, 'edited-app');
    await tester.ensureVisible(find.text('保存并重新加载弹幕'));
    await tester.tap(find.text('保存并重新加载弹幕'));
    await tester.pumpAndSettle();
    expect((await DandanplayCredentials.load()).appId, 'edited-app');
  });

  for (final landscape in [true, false]) {
    testWidgets('服务表单键盘弹出后凭证可见可输入，横屏=$landscape', (tester) async {
      final size = landscape ? const Size(956, 440) : const Size(440, 956);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(tester.view.reset);
      await open(tester);
      await select(tester, DandanplayCredentials.officialBase);
      for (final label in ['AppId', 'AppSecret']) {
        final field = find.widgetWithText(TextField, label);
        await tester.ensureVisible(field);
        await tester.tap(field);
        tester.view.viewInsets = FakeViewPadding(
          bottom: 280 * tester.view.devicePixelRatio,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        final rect = tester.getRect(field);
        final panel = tester.getRect(
          find.byKey(const ValueKey('danmaku-panel-frame')),
        );
        expect(rect.top, greaterThanOrEqualTo(panel.top));
        expect(rect.bottom, lessThanOrEqualTo(size.height - 280));
        expect(MediaQuery.viewInsetsOf(tester.element(field)).bottom, 0);
        await tester.enterText(field, 'typed-$label');
        expect(
          tester.widget<TextField>(field).controller!.text,
          'typed-$label',
        );
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
      }
    });
  }
}
