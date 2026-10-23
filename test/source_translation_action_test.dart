import 'dart:io';

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

  testWidgets('图标翻译后替换展示文字，再点切回原文', (tester) async {
    messenger.setMockMethodCallHandler(TextTranslationService.channel, (
      call,
    ) async {
      expect(call.method, 'translate');
      expect((call.arguments as Map)['texts'], ['Hello world']);
      return ['你好世界'];
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SourceText('Hello world'),
              SourceTranslationAction(texts: ['Hello world']),
            ],
          ),
        ),
      ),
    );
    expect(find.byTooltip('翻译成中文'), findsOneWidget);
    expect(find.text('翻译成中文'), findsNothing);
    await tester.tap(find.byTooltip('翻译成中文'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(find.text('你好世界'), findsOneWidget);
    await tester.tap(find.byTooltip('显示原文'));
    await tester.pumpAndSettle();
    expect(find.text('Hello world'), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SourceTranslationAction(texts: [])),
      ),
    );
    await tester.tap(find.byTooltip('翻译成中文'));
    await tester.pump();
    expect(find.text('当前没有可翻译的内容，请等待加载完成'), findsOneWidget);
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    messenger.setMockMethodCallHandler(TextTranslationService.channel, (
      _,
    ) async {
      throw PlatformException(code: 'translation', message: '系统不支持此语言组合');
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SourceTranslationAction(texts: ['Untranslated'])),
      ),
    );
    await tester.tap(find.byTooltip('翻译成中文'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(find.text('系统不支持此语言组合'), findsOneWidget);
    expect(TextTranslationService.shared.lookup('Untranslated'), isNull);
    var flushed = false;
    TextTranslationService.shared.flush().then((_) => flushed = true);
    for (var i = 0; i < 30 && !flushed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(flushed, isTrue);
  });
}
