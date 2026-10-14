import 'package:lume_box/features/video/source_playback.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/waf.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('图片使用源验证UA并要求原生按图片域名选择验证Cookie，Dart不复制Cookie', () async {
    final root = Directory.systemTemp.createTempSync('lume-image-session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final library = await ReadingLibrary.open(Section.comic);
    const source = MockDataSource(section: Section.comic);
    WafSessions.saveUserAgent(Section.comic, source.id, 'verified-device-UA');
    WafSessions.save(Section.comic, source.id, {
      'cf_clearance': 'fixture-cookie',
    });
    NetworkRequest? sent;
    final pipeline = SectionImagePipeline(
      cacheDir: library.imageCacheDir,
      requestSender: (request) async {
        sent = request;
        return const NetworkResponse(
          statusCode: 200,
          body: [1, 2, 3],
          headers: {},
        );
      },
    );
    addTearDown(() async {
      pipeline.dispose();
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      WafSessions.resetForTesting();
      await SectionScope.closeAll();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      root.deleteSync(recursive: true);
    });
    final video = VideoContent(
      url: Uri.parse('https://independent.cdn/video.mp4'),
      headers: const {
        'user-agent': 'source-static-UA',
        'Referer': 'https://source.example/',
      },
      qualities: [
        VideoQuality(
          label: '1080p',
          url: Uri.parse('https://independent.cdn/1080.mp4'),
        ),
      ],
    );
    final mediaHeaders = SourcePlayback.contentHeaders(video, source: source);
    expect(mediaHeaders['User-Agent'], 'verified-device-UA');
    expect(mediaHeaders.containsKey('Cookie'), false, reason: '主站会话不发给独立媒体CDN');
    expect(mediaHeaders.containsKey('user-agent'), false);
    expect(
      SourcePlayback.contentQualities(video, source: source).single.headers,
      mediaHeaders,
    );
    pipeline.bindSource(source);
    await pipeline.bytes('https://images.example/a.jpg');
    expect(sent!.headers['User-Agent'], 'verified-device-UA');
    expect(sent!.reuseVerifiedSession, true);
    expect(sent!.headers.containsKey('Cookie'), false);
  });
}
