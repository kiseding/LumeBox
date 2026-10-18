import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_experience_store.dart';
import 'package:lume_box/core/player/reference_player_factory.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/video/reference_player_settings.dart';
import 'package:lume_box/features/video/video_player_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('lumebox-reference-isolation-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => call.method == 'getApplicationSupportDirectory' ? root.path : null);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll(); ReadingStore.disposeAll(); await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  test('reference defaults, rate and appearance never overwrite original settings', () async {
    final original = await VideoPlayerSettingsStore.open();
    original.save(const PlayerSettings(kernel: PlayerKernel.mdk).copyWith(speed: 1.5, hardwareDecoding: false));
    final reference = await ReferencePlayerSettingsStore.open();
    expect(reference.load().kernel, PlayerKernel.mpv);
    reference.save(reference.load().copyWith(speed: 2, subtitlesEnabled: false));
    final experience = await PlayerExperienceStore.open(); experience.update({'mpvBufferMB': 730, 'mpvBufferSeconds': 310, 'longPressSpeed': 9.5});
    expect(original.load().kernel, PlayerKernel.mdk); expect(original.load().speed, 1.5); expect(original.load().hardwareDecoding, isFalse);
    expect(reference.load().speed, 2); expect(experience.value.mpvBufferMB, 730); expect(experience.value.mpvBufferSeconds, 310);
  });
  test('transient fallback preserves the chosen default kernel', () async {
    final reference = await ReferencePlayerSettingsStore.open();
    reference.save(const PlayerSettings(kernel: PlayerKernel.mpv));
    reference.save(reference.load().copyWith(kernel: PlayerKernel.mdk), preferredKernel: PlayerKernel.mpv);
    expect(reference.load().kernel, PlayerKernel.mpv);
  });
  test('temporary reference boost permits 10x without changing normal speed limits', () {
    const settings = PlayerSettings();
    expect(ReferenceTemporaryRate(settings, 10).speed, 10);
    expect(settings.speed, 1);
    expect(settings.copyWith(speed: 10).speed, PlayerSettings.maxSpeed);
  });
}
