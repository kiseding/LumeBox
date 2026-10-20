import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/shell/dock_liquid_settings.dart';
import 'package:lume_box/features/shell/dock_native_glass.dart';

void main() {
  testWidgets('原生底座创建期间修改配置，完成后同步最新圆角与主题', (tester) async {
    final gate = Completer<void>();
    final updates = <Map<Object?, Object?>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    MethodChannel? updateChannel;
    Map<Object?, Object?>? initial;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        initial = const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(args['params'] as Uint8List),
        ) as Map<Object?, Object?>;
        updateChannel = MethodChannel('lumebox/glass_backdrop_${args['id']}');
        messenger.setMockMethodCallHandler(updateChannel!, (call) async {
          updates.add(Map<Object?, Object?>.from(call.arguments as Map));
          return null;
        });
        await gate.future;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      if (updateChannel != null) {
        messenger.setMockMethodCallHandler(updateChannel!, null);
      }
    });
    Widget scene(double radius, Brightness brightness, bool reduced) =>
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          themeAnimationDuration: Duration.zero,
          home: Center(
            child: SizedBox(
              width: 300,
              height: 64,
              child: DockNativeGlass(
                borderRadius: BorderRadius.circular(radius),
                cornerRadius: radius,
                reduceTransparency: reduced,
              ),
            ),
          ),
        );
    await tester.pumpWidget(scene(32, Brightness.light, false));
    expect(initial?['cornerRadius'], 32);
    await tester.pumpWidget(scene(24, Brightness.dark, true));
    gate.complete();
    await tester.pumpAndSettle();
    expect(updates.last, {
      'style': 'regular',
      'cornerRadius': 24.0,
      'brightness': 'dark',
      'reduceTransparency': true,
    });
    final count = updates.length;
    await tester.pumpWidget(scene(24, Brightness.dark, true));
    expect(updates.length, count, reason: '相同配置不重复重建系统材质');
    await tester.pumpWidget(scene(30, Brightness.light, false));
    await tester.pumpAndSettle();
    expect(updates.last['cornerRadius'], 30);
    expect(updates.last['brightness'], 'light');
    expect(updates.last['reduceTransparency'], false);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('修改任一玻璃效果开关保留降低透明度偏好', () {
    final settings = const DockLiquidSettings().withReduceTransparency(true);
    for (final effect in DockLiquidEffect.values) {
      expect(settings.withEnabled(effect, false).reduceTransparency, isTrue);
    }
  });
}
