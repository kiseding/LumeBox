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
    // 用户自己调过的磨砂强度在迁移后仍然生效（底栏默认换材质不覆盖手动值）。
    expect(controller.style(FloatingModule.dock).blur, 6);
    final clamped = FloatingStyle.fromJson({
      'opacity': -1,
      'x': 400,
      'y': -900,
      'blur': 200,
    });
    expect(clamped.opacity, 0);
    expect(clamped.x, 40);
    expect(clamped.y, -40);
    expect(clamped.blur, 15);
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

  test('底栏新材质：白玻璃 65% + 磨砂 12，旧配置一次性迁移且之后仍可调', () async {
    final root = Directory.systemTemp.createTempSync('floating-dock-glass');
    addTearDown(() => root.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );

    expect(FloatingStyle.dockDefault.opacity, .65);
    expect(FloatingStyle.dockDefault.blur, 12);

    // 旧版配置：底栏只有位置/透明度，没有新材质的版本号。
    File('${root.path}/floating_modules.json').writeAsStringSync(
      jsonEncode({
        'dock': {'opacity': .9, 'x': 3, 'y': 4, 'blur': 2},
      }),
    );
    final controller = FloatingModules.instance;
    await controller.boot();
    final migrated = controller.style(FloatingModule.dock);
    expect(migrated.opacity, .65, reason: '一次性换成新白玻璃');
    expect(migrated.blur, 12, reason: '模糊半径落到 10–15 区间');
    expect(migrated.x, 3, reason: '迁移只换材质，不动用户摆的位置');
    expect(migrated.offset.dy, 4);

    // 迁移之后滑块照常生效：再次启动不能把用户的新值覆盖回去。
    controller.set(
      FloatingModule.dock,
      const FloatingStyle(opacity: .4, blur: 15),
    );
    controller.save();
    await controller.boot();
    expect(controller.style(FloatingModule.dock).opacity, .4);
    expect(controller.style(FloatingModule.dock).blur, 15);
  });
}
