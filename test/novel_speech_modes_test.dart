import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_settings.dart';
import 'package:lume_box/core/speech/speech_local.dart';
import 'package:lume_box/features/novel/novel_speech_modes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'four-mode selector disables missing offline model and switches online profile',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => '.cache/speech-unit-config',
          );
      SpeechLocalModel.instance.ready = false;
      var settings = const SpeechSettings(rate: .7);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => NovelSpeechModes(
                settings: settings,
                selectorOnly: true,
                onChanged: (value) => setState(() => settings = value),
              ),
            ),
          ),
        ),
      );
      final selector = tester.widget<DropdownButton<SpeechMode>>(
        find.byType(DropdownButton<SpeechMode>),
      );
      expect(selector.items!.length, 4);
      expect(
        selector.items!
            .singleWhere((item) => item.value == SpeechMode.local)
            .enabled,
        false,
      );
      await tester.tap(find.byType(DropdownButton<SpeechMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(SpeechMode.cloud.label).last);
      await tester.pumpAndSettle();
      expect(settings.mode, SpeechMode.cloud);
      expect(settings.rate, .5);
      expect(settings.copyWith(mode: SpeechMode.system).rate, .7);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('reader help stays collapsed until explicitly expanded', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: novelSpeechHelp)),
      ),
    );
    expect(find.text('📖听书功能使用帮助'), findsOneWidget);
    expect(find.textContaining('【四种听书模式新手教程】'), findsNothing);
    await tester.tap(find.text('📖听书功能使用帮助'));
    await tester.pumpAndSettle();
    expect(find.textContaining('【四种听书模式新手教程】'), findsOneWidget);
  });
}
