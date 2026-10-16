import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class SpeechLocalModel extends ChangeNotifier {
  static final instance = SpeechLocalModel();
  static const assets = 'assets/speech/vits_aishell3';
  bool ready = false, preparing = false;
  String? error;
  Directory? directory;
  Future<Map<String, dynamic>> get _manifest async =>
      jsonDecode(await rootBundle.loadString('$assets/manifest.json'))
          as Map<String, dynamic>;
  Future<bool> check() async {
    final support = await getApplicationSupportDirectory();
    directory = Directory('${support.path}/speech/vits_aishell3');
    final manifest = await _manifest;
    final path = directory!.path;
    ready = await Isolate.run(() => _valid(path, manifest));
    notifyListeners();
    return ready;
  }

  static Future<bool> _valid(
    String directory,
    Map<String, dynamic> manifest,
  ) async {
    for (final item in manifest['files'] as List) {
      final file = File('$directory/${item['name']}');
      if (!await file.exists() ||
          await file.length() != item['bytes'] ||
          (await sha256.bind(file.openRead()).first).toString() !=
              item['sha256']) {
        return false;
      }
    }
    return true;
  }

  Future<void> prepare() async {
    if (preparing) return;
    preparing = true;
    ready = false;
    error = null;
    notifyListeners();
    Directory? staging;
    try {
      final support = await getApplicationSupportDirectory();
      directory = Directory('${support.path}/speech/vits_aishell3');
      final parent = Directory('${support.path}/speech');
      await parent.create(recursive: true);
      staging = await parent.createTemp('prepare-');
      final archive = File('${staging.path}/pack.tar.bz2');
      final sink = archive.openWrite();
      final manifest = await _manifest;
      try {
        for (final part in manifest['parts'] as List) {
          final data = await rootBundle.load('$assets/${part['name']}');
          final bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          if (bytes.length != part['bytes'] ||
              sha256.convert(bytes).toString() != part['sha256']) {
            throw const FormatException('内置模型资源校验失败');
          }
          sink.add(bytes);
          await sink.flush();
        }
      } finally {
        await sink.close();
      }
      final path = staging.path;
      await Isolate.run(() async {
        if ((await sha256.bind(File('$path/pack.tar.bz2').openRead()).first)
                .toString() !=
            manifest['archiveSha256']) {
          throw const FormatException('模型压缩包校验失败');
        }
        final input = InputFileStream('$path/pack.tar.bz2');
        final output = OutputFileStream('$path/pack.tar');
        try {
          BZip2Decoder().decodeStream(input, output);
        } finally {
          input.close();
          output.close();
        }
        final tar = InputFileStream('$path/pack.tar');
        try {
          final archive = TarDecoder().decodeStream(tar);
          final wanted = {
            for (final file in manifest['files'] as List)
              file['name'] as String,
          };
          await Directory('$path/model').create();
          for (final entry in archive) {
            final name = entry.name.replaceAll('\\', '/').split('/').last;
            if (!wanted.contains(name) || !entry.isFile || entry.isSymbolicLink) {
              continue;
            }
            final target = OutputFileStream('$path/model/$name');
            try {
              entry.writeContent(target);
            } finally {
              target.close();
            }
          }
        } finally {
          tar.close();
        }
        if (!await _valid('$path/model', manifest)) {
          throw const FormatException('模型文件校验失败');
        }
      });
      // Only the owned model directory is replaced, after complete validation.
      if (await directory!.exists()) await directory!.delete(recursive: true);
      await Directory('${staging.path}/model').rename(directory!.path);
      ready = true;
    } catch (_) {
      error = '模型准备失败，请检查剩余空间后重试';
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      preparing = false;
      notifyListeners();
    }
  }
}

/// A cancellable per-playback worker. The native callback delivers generated
/// chunks without blocking Flutter's UI isolate. No network or LLM is involved.
class SpeechLocalVoice {
  Future<_LocalSpeechWorker>? _worker;
  void close() {
    final current = _worker;
    _worker = null;
    if (current != null) {
      unawaited(current.then((worker) => worker.close(), onError: (_) {}));
    }
  }

  Stream<Uint8List> synthesize(
    String text,
    String path,
    int voice,
    double speed,
  ) async* {
    final worker = await (_worker ??= _LocalSpeechWorker.create(path));
    if (worker.closed) return;
    worker.commands.send([text, voice, speed]);
    while (!worker.closed && await worker.messages.moveNext()) {
      final message = worker.messages.current;
      if (message == 'done') return;
      if (message == 'error') throw const FormatException('离线语音合成失败');
      if (message is TransferableTypedData) {
        yield message.materialize().asUint8List();
      }
    }
  }

  static void generate(List<Object> args) async {
    final send = args[0] as SendPort;
    final commands = ReceivePort();
    sherpa.OfflineTts? tts;
    try {
      sherpa.initBindings();
      final path = args[1] as String;
      tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            numThreads: 2,
            debug: false,
            vits: sherpa.OfflineTtsVitsModelConfig(
              model: '$path/vits-aishell3.onnx',
              lexicon: '$path/lexicon.txt',
              tokens: '$path/tokens.txt',
            ),
          ),
          ruleFsts: [
            'date',
            'number',
            'new_heteronym',
            'phone',
          ].map((n) => '$path/$n.fst').join(','),
          maxNumSenetences: 1,
        ),
      );
      if (tts.sampleRate != 8000 || tts.numSpeakers < 1) {
        throw const FormatException('模型音频格式无效');
      }
      send.send(commands.sendPort);
      await for (final request in commands) {
        if (request == 'close') break;
        final job = request as List;
        tts.generateWithCallback(
          text: job[0] as String,
          sid: (job[1] as int).clamp(0, tts.numSpeakers - 1),
          speed: job[2] as double,
          callback: (samples) {
            final bytes = ByteData(samples.length * 2);
            for (var i = 0; i < samples.length; i++) {
              bytes.setInt16(
                i * 2,
                (samples[i].clamp(-1, 1) * 32767).round(),
                Endian.little,
              );
            }
            send.send(
              TransferableTypedData.fromList([bytes.buffer.asUint8List()]),
            );
            return 1;
          },
        );
        send.send('done');
      }
    } catch (_) {
      send.send('error');
    } finally {
      tts?.free();
      commands.close();
    }
  }
}

class _LocalSpeechWorker {
  _LocalSpeechWorker(this.port, this.messages, this.commands);
  final ReceivePort port;
  final StreamIterator<dynamic> messages;
  final SendPort commands;
  bool closed = false;
  static Future<_LocalSpeechWorker> create(String path) async {
    final port = ReceivePort();
    final messages = StreamIterator(port);
    await Isolate.spawn(SpeechLocalVoice.generate, [port.sendPort, path]);
    if (!await messages.moveNext() || messages.current is! SendPort) {
      port.close();
      await messages.cancel();
      throw const FormatException('无法加载离线语音模型');
    }
    return _LocalSpeechWorker(port, messages, messages.current as SendPort);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    // Never kill an isolate inside FFI: it must free the native ONNX model.
    // Stop audio immediately; let the bounded current sentence finish privately.
    commands.send('close');
    port.close();
    await messages.cancel();
  }
}
