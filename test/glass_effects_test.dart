import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/glass_effects_settings.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
import 'package:lume_box/shared/widgets/liquid_glass_widget.dart';
import 'package:lume_box/shared/widgets/player_popup_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('glass-effects-');
    await GlassEffectsSettings.instance.boot(directory: directory);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'defaults, rapid writes and reload are independent of floating config',
    () async {
      final legacy = File('${directory.path}/floating_modules.json');
      const original = '{"dock":{"blur":3,"opacity":0.4},"custom":true}';
      legacy.writeAsStringSync(original);
      final settings = GlassEffectsSettings.instance;
      expect(settings.liquidEnabled, false);
      expect(settings.playerFrostedEnabled, true);
      await Future.wait([
        settings.setLiquidEnabled(true),
        settings.setPlayerFrostedEnabled(false),
        settings.setLiquidEnabled(false),
        settings.setLiquidEnabled(true),
      ]);
      final restored = GlassEffectsSettings();
      await restored.boot(directory: directory);
      expect(restored.liquidEnabled, true);
      expect(restored.playerFrostedEnabled, false);
      expect(legacy.readAsStringSync(), original);
      restored.dispose();
    },
  );

  test('malformed fields safely preserve independent defaults', () async {
    File('${directory.path}/${GlassEffectsSettings.fileName}')
        .writeAsStringSync(
          jsonEncode({'liquidEnabled': 'true', 'playerFrostedEnabled': null}),
        );
    await GlassEffectsSettings.instance.boot(directory: directory);
    expect(GlassEffectsSettings.instance.liquidEnabled, false);
    expect(GlassEffectsSettings.instance.playerFrostedEnabled, true);
  });

  testWidgets(
    'liquid off preserves legacy element, hit target and no effect layers',
    (tester) async {
      var taps = 0;
      final oldButton = SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          onPressed: () => taps++,
          icon: const Icon(Icons.play_arrow),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LiquidGlassWidget(
              blur: 40,
              highlight: 1,
              distort: 1,
              opacity: 1,
              child: oldButton,
            ),
          ),
        ),
      );
      expect(find.byWidget(oldButton), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ClipRRect), findsNothing);
      expect(tester.getSize(find.byWidget(oldButton)), const Size(48, 48));
      await tester.tap(find.byType(IconButton));
      expect(taps, 1);
      if (!ui.ImageFilter.isShaderFilterSupported) {
        await tester.runAsync(
          () => GlassEffectsSettings.instance.setLiquidEnabled(true),
        );
        await tester.pump();
        expect(find.byWidget(oldButton), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
      }
    },
  );

  testWidgets('frosted uses its parameters independent of old module sliders', (
    tester,
  ) async {
    FloatingModules.instance.set(
      FloatingModule.overlay,
      const FloatingStyle(blur: 1, opacity: .1),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FrostedGlassWidget(
            blur: 24,
            opacity: .6,
            radius: 14,
            border: false,
            child: SizedBox(width: 200, height: 100),
          ),
        ),
      ),
    );
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter, ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24));
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(FrostedGlassWidget),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect((box.decoration as BoxDecoration).border, null);
    expect((box.decoration as BoxDecoration).color!.a, closeTo(.6, .005));
    FloatingModules.instance.reset(FloatingModule.overlay);
  });

  testWidgets(
    'player switch returns actual old background and never a weakened new effect',
    (tester) async {
      const legacy = ColoredBox(color: Colors.red, child: Text('old player'));
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: PlayerPopupGlass(legacy: legacy, child: Text('new player')),
          ),
        ),
      );
      expect(find.byType(FrostedGlassWidget), findsOneWidget);
      expect(find.text('new player'), findsOneWidget);
      await tester.runAsync(
        () => GlassEffectsSettings.instance.setPlayerFrostedEnabled(false),
      );
      await tester.pump();
      expect(find.byWidget(legacy), findsOneWidget);
      expect(find.byType(FrostedGlassWidget), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('new player'), findsNothing);
      await tester.runAsync(
        () => GlassEffectsSettings.instance.setPlayerFrostedEnabled(true),
      );
      await tester.pump();
      expect(find.byType(FrostedGlassWidget), findsOneWidget);
    },
  );
}
