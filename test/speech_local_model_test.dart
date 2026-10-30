import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/models/model_source.dart';
import 'package:lume_box/core/speech/speech_local.dart';

/// 下载源换成假的：单测不该连 Hugging Face，也不该依赖仓库里那份 118 MB 权重。
typedef _Fetcher =
    Future<void> Function(
      Map<String, dynamic> manifest,
      Map<String, dynamic> file,
      File target,
      void Function(int received, int? total)? onProgress,
    );

Map<String, dynamic> _manifestFor(Map<String, Uint8List> files) => {
  'sources': ['https://example.invalid/model/'],
  'archiveSha256': '0' * 64,
  'files': [
    for (final entry in files.entries)
      {
        'name': entry.key,
        'bytes': entry.value.length,
        'sha256': sha256.convert(entry.value).toString(),
      },
  ],
  'speakers': 174,
  'sampleRate': 8000,
};

_Fetcher _writer(Map<String, Uint8List> data) =>
    (manifest, file, target, onProgress) async {
      final bytes = data[file['name']]!;
      await target.writeAsBytes(bytes, flush: true);
      onProgress?.call(bytes.length, bytes.length);
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首次启用按清单下载逐份校验；损坏的导入保留已装模型', () async {
    final root = await Directory.systemTemp.createTemp('lumebox-vits-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final payload = <String, Uint8List>{
      'tokens.txt': Uint8List.fromList(List.generate(64, (i) => i)),
      'vits-aishell3.onnx': Uint8List.fromList(List.generate(2048, (i) => i % 251)),
    };
    final manifest = _manifestFor(payload);
    final model = SpeechLocalModel(
      loadManifest: () async => manifest,
      fetchFile: _writer(payload),
    );
    try {
      expect(await model.check(), false);
      expect(await model.prepare(), true);
      expect(model.ready, true);
      expect(model.error, isNull);
      expect(model.received, model.total, reason: '进度应走到 100%');
      expect(await model.check(), true);
      for (final entry in payload.entries) {
        expect(
          await File('${model.directory!.path}/${entry.key}').readAsBytes(),
          entry.value,
        );
      }
      expect(
        await File('${model.directory!.path}/rule.far').exists(),
        false,
        reason: '180 MB 的 FAR 数据不属于运行期文件',
      );

      // 手动导入一份坏包：报校验失败，但已装好的模型不能被动过。
      final broken = File('${root.path}/voice.tar.bz2');
      await broken.writeAsString('incomplete archive');
      expect(await model.prepare(archiveFile: XFile(broken.path)), false);
      expect(model.error, contains('校验失败'));
      expect(model.ready, true);
      expect(await model.check(), true);

      final tokens = File('${model.directory!.path}/tokens.txt');
      await tokens.writeAsString('tampered');
      expect(await model.check(), false);
      expect(model.ready, false);
    } finally {
      model.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('下载失败给出网络原因，且不破坏已安装的音色包', () async {
    final root = await Directory.systemTemp.createTemp('lumebox-vits-fail-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final payload = <String, Uint8List>{
      'tokens.txt': Uint8List.fromList(List.generate(32, (i) => i)),
    };
    final manifest = _manifestFor(payload);
    final good = SpeechLocalModel(
      loadManifest: () async => manifest,
      fetchFile: _writer(payload),
    );
    addTearDown(good.dispose);
    expect(await good.prepare(), true);
    final installed = good.directory!.path;

    final offline = SpeechLocalModel(
      loadManifest: () async => manifest,
      fetchFile: (manifest, file, target, onProgress) async =>
          throw const ModelDownloadException('下载失败：HTTP 503'),
    );
    try {
      expect(await offline.prepare(), false);
      expect(offline.error, contains('下载失败'));
      expect(offline.ready, false);
      offline.directory = Directory(installed);
      expect(await offline.check(), true, reason: '失败的下载不得动已装文件');
    } finally {
      offline.dispose();
      await root.delete(recursive: true);
    }
  });

  test('iOS picker types are present and cancellation or platform failure is reported safely', () async {
    expect(
      SpeechLocalModel.archiveType.uniformTypeIdentifiers,
      contains('public.data'),
    );
    final picked = Completer<XFile?>();
    final model = SpeechLocalModel(pickArchive: () => picked.future);
    final installing = model.prepare(fromFile: true);
    expect(model.preparing, true);
    expect(await model.prepare(fromFile: true), false);
    picked.complete(null);
    expect(await installing, false);
    expect(model.preparing, false);
    expect(model.ready, false);
    expect(model.error, isNull);
    model.dispose();
    final broken = SpeechLocalModel(
      pickArchive: () async => throw PlatformException(code: 'picker_failed'),
    );
    expect(await broken.prepare(fromFile: true), false);
    expect(broken.preparing, false);
    expect(broken.error, contains('无法打开文件选择器'));
    broken.dispose();
  });
}
