import 'dart:io';

import 'package:lume_box/core/reading/comic_image_tools_settings.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/translation/text_translation.dart';
import 'package:lume_box/shared/widgets/source_translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('source-translation-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    await TextTranslationService.shared.boot();
  });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(TextTranslationService.channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await directory.delete(recursive: true);
  });

  testWidgets('全局实时翻译自动启动，关闭与重启偏好生效', (tester) async {
    final settings = ComicImageToolsSettings.instance;
    settings.liveTranslation = true;
    var calls = 0;
    messenger.setMockMethodCallHandler(TextTranslationService.channel, (
      call,
    ) async {
      calls++;
      return [for (final text in (call.arguments as Map)['texts']) '译$text'];
    });
    Widget app(List<String> texts) => MaterialApp(
      home: Scaffold(body: SourceTranslationAction(texts: texts)),
    );
    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 700));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
    }

    Future<void> persist() async {
      var done = false;
      settings.save().then((_) => done = true);
      for (var i = 0; i < 50 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump();
      }
      expect(done, isTrue);
    }

    await tester.pumpWidget(app(['Global first']));
    await settle();
    expect(calls, 1);
    settings.liveTranslation = false;
    await persist();
    await tester.pumpWidget(app(['Global next']));
    await settle();
    expect(calls, 1);
    settings.liveTranslation = true;
    await persist();
    await settle();
    expect(calls, 2);
    final restored = ComicImageToolsSettings();
    await tester.runAsync(() => restored.boot());
    expect(restored.liveTranslation, isTrue);
    settings.liveTranslation = false;
    await persist();
    await tester.pumpWidget(const SizedBox.shrink());
    var flushed = false;
    TextTranslationService.shared.flush().then((_) => flushed = true);
    for (var i = 0; i < 50 && !flushed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(flushed, isTrue);
  });
}
