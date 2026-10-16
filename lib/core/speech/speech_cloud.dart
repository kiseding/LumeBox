import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'speech_turns.dart';

/// Non-secret preferences live in one local file. Secrets use the device-only
/// Keychain and are never included in this JSON or a request to another host.
class SpeechCloudConfig {
  static final instance = SpeechCloudConfig();
  String ttsUrl = '', ttsModel = '', llmUrl = '', llmModel = '';
  List<String> llmModels = [];
  Future<void>? _loading;
  static const _channel = MethodChannel('lumebox/speech');
  Future<File> get _file async => File(
    '${(await getApplicationSupportDirectory()).path}/speech_cloud.json',
  );
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    final file = await _file;
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      String field(String key) =>
          data[key] is String ? data[key] as String : '';
      ttsUrl = field('ttsUrl');
      ttsModel = field('ttsModel');
      llmUrl = field('llmUrl');
      llmModel = field('llmModel');
      if (data['llmModels'] is List) {
        llmModels = (data['llmModels'] as List)
            .whereType<String>()
            .toSet()
            .toList();
      }
    } on FormatException {
      /* Corrupt configuration has safe empty defaults. */
    }
  }

  Future<void> save() async {
    final file = await _file;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'ttsUrl': ttsUrl,
        'ttsModel': ttsModel,
        'llmUrl': llmUrl,
        'llmModel': llmModel,
        'llmModels': llmModels,
      }),
      flush: true,
    );
    await temp.rename(file.path);
  }

  Future<String> key(String kind) async =>
      await _channel.invokeMethod<String>('speechGetKey', {'kind': kind}) ?? '';
  Future<void> setKey(String kind, String key) =>
      _channel.invokeMethod<void>('speechSetKey', {'kind': kind, 'key': key});

  static Uri endpoint(String raw, String suffix) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请填写有效的 HTTPS 接口地址');
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith(suffix)) return uri.replace(path: path);
    return uri.replace(
      path: '$path${path.endsWith('/v1') ? '' : '/v1'}$suffix',
    );
  }
}

class SpeechCloudClient {
  SpeechCloudClient(this.config, {http.Client? client})
    : client = client ?? http.Client();
  final SpeechCloudConfig config;
  final http.Client client;
  void close() => client.close();

  Future<http.StreamedResponse> _post(
    Uri uri,
    String key,
    Map<String, Object?> body,
  ) async {
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (key.isNotEmpty) 'Authorization': 'Bearer $key',
      })
      ..body = jsonEncode(body);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Do not copy provider bodies/headers: they may contain credentials.
      await response.stream.listen(null).cancel();
      throw HttpException('语音服务返回 ${response.statusCode}');
    }
    return response;
  }

  Future<List<SpeechTurn>> annotate(String chapter) async {
    await config.load();
    if (config.llmModel.trim().isEmpty) {
      throw const FormatException('请填写大模型名称');
    }
    final response = await _post(
      SpeechCloudConfig.endpoint(config.llmUrl, '/chat/completions'),
      await config.key('llm'),
      {
        'model': config.llmModel,
        'stream': false,
        'messages': [
          {
            'role': 'system',
            'content': 'Return only SSML <speak>. Keep every character of the user chapter in its original order, without rewriting, summarizing or omission. Use <voice name="narrator|male|female"> for narration and dialogue, and <break time="250ms"/> for pauses. No other voice names. No markdown.',
          },
          {'role': 'user', 'content': chapter},
        ],
      },
    );
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > chapter.length * 24 + 65536) {
        throw const FormatException('大模型返回内容过大');
      }
    }
    final data = jsonDecode(utf8.decode(bytes));
    final content = data['choices'][0]['message']['content'];
    if (content is! String) throw const FormatException('大模型响应格式无效');
    return SpeechTurns.ssml(content, chapter);
  }

  /// Raw signed 16-bit mono PCM at 24 kHz. Awaiting the consumer provides
  /// backpressure all the way from the native audio queue to HTTP.
  Stream<List<int>> audio(String text, String voice, double speed) async* {
    await config.load();
    if (config.ttsModel.trim().isEmpty) {
      throw const FormatException('请填写 TTS 模型名称');
    }
    final response = await _post(
      SpeechCloudConfig.endpoint(config.ttsUrl, '/audio/speech'),
      await config.key('tts'),
      {
        'model': config.ttsModel,
        'input': text,
        'voice': voice.isEmpty ? 'alloy' : voice,
        'response_format': 'pcm',
        'speed': speed.clamp(.25, 4),
      },
    );
    var size = 0;
    await for (final bytes in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      size += bytes.length;
      if (size > 48 * 1024 * 1024) throw const FormatException('音频响应过大');
      yield bytes;
    }
    if (size == 0) throw const FormatException('服务未返回音频');
  }
}
