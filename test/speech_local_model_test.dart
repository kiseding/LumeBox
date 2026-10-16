import 'dart:io';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('imported pack prepares verified files; missing/tampered models stay unavailable', () async {
    final root = await Directory.systemTemp.createTemp('lumebox-vits-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final model = SpeechLocalModel();
    try {
      expect(await model.check(), false);
      final manifest = jsonDecode(
        await File('assets/speech/vits_aishell3/manifest.json').readAsString(),
      ) as Map<String, dynamic>;
      final archive = File('${root.path}/voice.tar.bz2');
      final sink = archive.openWrite();
      for (final part in manifest['parts'] as List) {
        await sink.addStream(
          File('assets/speech/vits_aishell3/${part['name']}').openRead(),
        );
      }
      await sink.close();
      await model.prepare(archiveFile: XFile(archive.path));
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
