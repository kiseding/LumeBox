/// Mobile preview and native smoke check. Does not change the shipping entry.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lume_box/core/intro/intro_backend.dart';
import 'package:lume_box/core/intro/intro_models.dart';
import 'package:lume_box/core/intro/intro_signals.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/reference_player_factory.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/intro_settings_page.dart';
import 'package:lume_box/features/video/player_choice.dart';
import 'package:lume_box/features/video/reference_player_page.dart';

const fixtureURL = String.fromEnvironment(
  'PREVIEW_MEDIA',
  defaultValue: 'http://127.0.0.1:8765/player-fixture.mp4',
);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPreferences.instance.boot();
  await FloatingModules.instance.boot();
  await FrostedSettings.instance.boot();
  await ReadingLibrary.open(Section.video);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(brightness: Brightness.light),
      home: const _Home(),
    ),
  );
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  String _result = '测试媒体：原创测试画面／音调，含 OP、正片、ED 章节标记。';
  bool _busy = false;
  Future<void> _smoke() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = '原生取帧、音频、OCR 与 YAMNet 推理中…';
    });
    final backend = NativeIntroBackend();
    try {
      final options = IntroOptions({'videoAI': false, 'audioAI': true});
      final resources = await backend.resources();
      final sample = await backend.sample(
        Uri.parse(fixtureURL),
        {},
        7000,
        options,
        IntroCancellation(),
      );
      if (sample == null) throw StateError('No native sample');
      final inference = await backend.infer(sample, options);
      final result = const JsonEncoder.withIndent('  ').convert({
        'resources': resources,
        'grayPixels': sample.gray.length,
        'pcmSamples': sample.pcm.length,
        'audioRMS': IntroSignals.rms(sample.pcm),
        'ocr': sample.text,
        'yamnet': inference.ai,
      });
      debugPrint('INTRO_NATIVE_SMOKE $result');
      if (mounted) setState(() => _result = result);
    } catch (error, stack) {
      debugPrint('INTRO_NATIVE_SMOKE_FAILURE $error\n$stack');
      if (mounted) setState(() => _result = '$error');
    } finally {
      await backend.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放器移动端预览')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton(
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => ReferencePlayerPage(
                playerFactory: (kernel) => ReferencePlayerFactory.create(
                  kernel,
                  emulatorSurfacePreview: true,
                ),
                media: PlayerMedia(
                  uri: Uri.parse(fixtureURL),
                  title: 'LumeBox 测试影片',
                ),
                title: '参考播放器',
                fullscreenOnly: false,
              ),
            ),
          ),
          child: const Text('打开参考播放器（模拟器直连 Surface）'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const IntroSettingsPage()),
          ),
          child: const Text('片头片尾全部识别设置'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const PlayerChoiceSettingsPage()),
          ),
          child: const Text('两套播放器切换与设置'),
        ),
        const SizedBox(height: 20),
        FilledButton.tonal(
          onPressed: _busy ? null : _smoke,
          child: const Text('运行原生采样与 YAMNet 检查'),
        ),
        const SizedBox(height: 16),
        SelectableText(_result),
      ],
    ),
  );
}
