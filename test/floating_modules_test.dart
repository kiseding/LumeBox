import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/floating_modules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('悬浮模块独立保存，读入越界值收敛且底栏可向下调', () async {
    final root = Directory.systemTemp.createTempSync('floating-modules');
    addTearDown(() => root.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final controller = FloatingModules.instance;
    await controller.boot();
    controller.set(
      FloatingModule.home,
      const FloatingStyle(opacity: .1, y: 12, blur: 4),
    );
    controller.set(
      FloatingModule.dock,
      const FloatingStyle(opacity: .3, y: 20),
    );
    controller.save();
    controller.reset(FloatingModule.home);
    await controller.boot();
    expect(controller.style(FloatingModule.home).opacity, .1);
    expect(controller.style(FloatingModule.home).y, 12);
    expect(controller.style(FloatingModule.dock).opacity, .3);
    final clamped = FloatingStyle.fromJson({
      'opacity': -1,
      'x': 400,
      'y': -900,
      'blur': 200,
    });
    expect(clamped.opacity, 0);
    expect(clamped.x, 40);
    expect(clamped.y, -40);
    expect(clamped.blur, 6);
    File('${root.path}/floating_modules.json').writeAsStringSync(
      jsonEncode({
        'home': {'opacity': .7, 'x': 8, 'y': 19, 'blur': 24},
      }),
    );
    await controller.boot();
    expect(controller.style(FloatingModule.home).opacity, .72);
    expect(controller.style(FloatingModule.home).offset.dx, 8);
    expect(controller.style(FloatingModule.home).offset.dy, 19);
    expect(controller.style(FloatingModule.home).blur, 6);
    // Once migrated, newly chosen opacity remains under the user's control.
    controller.set(FloatingModule.home, const FloatingStyle(opacity: .4));
    controller.save();
    await controller.boot();
    expect(controller.style(FloatingModule.home).opacity, .4);
  });
}
