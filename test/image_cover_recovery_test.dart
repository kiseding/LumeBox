import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('cover-recovery'));
  tearDown(() => root.deleteSync(recursive: true));
  test('403 后确实移除源指定的 Referer，不重复发送同一请求头', () async {
    final requests = <NetworkRequest>[];
    final pipeline = SectionImagePipeline(
      cacheDir: root.path,
      maxRetries: 1,
      requestSender: (request) async {
        requests.add(request);
        return NetworkResponse(
          statusCode: requests.length == 1 ? 403 : 200,
          body: requests.length == 1 ? [] : [1, 2, 3],
          headers: {},
        );
      },
    );
    addTearDown(pipeline.dispose);
    const url = 'https://cdn.example/cover.jpg';
    pipeline.configureImageHeaders({
      url: {'Referer': 'https://source.example/', 'X-Image': 'keep'},
    });
    expect(await pipeline.bytes(url), [1, 2, 3]);
    expect(requests.first.headers['Referer'], 'https://source.example/');
    expect(
      requests.last.headers.keys.where((k) => k.toLowerCase() == 'referer'),
      isEmpty,
    );
    expect(requests.last.headers['X-Image'], 'keep');
  });
  test('200 校验网页不写入图片缓存；证书错误不反复排队', () async {
    var attempts = 0;
    final pipeline = SectionImagePipeline(
      cacheDir: root.path,
      requestSender: (request) async {
        attempts++;
        if (request.url.contains('expired')) {
          throw const HandshakeException(
            'CERTIFICATE_VERIFY_FAILED: certificate has expired',
          );
        }
        return NetworkResponse(
          statusCode: 200,
          body: '<!DOCTYPE html><html>challenge</html>'.codeUnits,
          headers: {},
        );
      },
    );
    addTearDown(pipeline.dispose);
    const html = 'https://cdn.example/challenge.jpg';
    expect(await pipeline.bytes(html), isNull);
    expect(File(pipeline.cachePathFor(html)).existsSync(), false);
    expect(pipeline.failureFor(html), '非图片响应');
    expect(await pipeline.bytes('https://cdn.example/expired.jpg'), isNull);
    expect(pipeline.canRetry('https://cdn.example/expired.jpg'), false);
    expect(attempts, 2);
  });
  testWidgets('旧损坏封面缓存被移除并重新下载解码', (tester) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = Colors.purple,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(4, 4);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      var requests = 0;
      final pipeline = SectionImagePipeline(
        cacheDir: root.path,
        requestSender: (_) async {
          requests++;
          return NetworkResponse(
            statusCode: 200,
            body: png!.buffer.asUint8List(),
            headers: {},
          );
        },
      );
      const url = 'https://cdn.example/cover.png';
      File(pipeline.cachePathFor(url))
          .writeAsStringSync('<html>old cached challenge</html>');
      final decoded = await pipeline.image(url);
      expect(decoded?.width, 4);
      expect(requests, 1);
      expect(pipeline.failureFor(url), null);
      pipeline.release(url);
      pipeline.dispose();
    });
  });
}
