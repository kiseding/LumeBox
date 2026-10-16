import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bundled pack prepares verified files; missing/tampered models stay unavailable', () async {
    final root = await Directory.systemTemp.createTemp('lumebox-vits-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final model = SpeechLocalModel();
    try {
      expect(await model.check(), false);
      await model.prepare();
      expect(model.error, isNull);
      expect(model.ready, true);
      expect(await model.check(), true);
      expect(
        await File('${model.directory!.path}/rule.far').exists(),
        false,
        reason: 'Unused 180 MB FAR data must not be extracted',
      );
      final tokens = File('${model.directory!.path}/tokens.txt');
      await tokens.writeAsString('tampered');
      expect(await model.check(), false);
      expect(model.ready, false);
    } finally {
      model.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
