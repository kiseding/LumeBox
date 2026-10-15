import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:lume_box/features/video/tmdb_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('缺省关闭且不内置 Key，关闭和空 Key 时不产生请求', () async {
    final settings = TmdbSettings();
    var calls = 0;
    final client = TmdbClient(
      settings,
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    expect(settings.enabled, isFalse);
    expect(settings.apiKey, isEmpty);
    expect(await client.lookup('影片'), isNull);
    expect(calls, 0);
    await expectLater(client.testApi(), throwsStateError);
    expect(calls, 0);
    settings.enabled = true;
    expect(await client.lookup('影片'), isNull);
    expect(calls, 0);
    client.dispose();
  });
  test('本地配置重开与断开连接', () async {
    final root = Directory.systemTemp.createTempSync('tmdb-settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final settings = TmdbSettings();
    await settings.boot();
    settings.enabled = true;
    settings.apiKey = 'fixture-key';
    settings.apiProxy = 'proxy.test/3';
    settings.imageProxy = 'https://img.test/t/p/';
    settings.posterStyle = TmdbPosterStyle.carousel;
    await settings.save();
    final reopened = TmdbSettings();
    await reopened.boot();
    expect(reopened.apiKey, 'fixture-key');
    expect(reopened.posterStyle, TmdbPosterStyle.carousel);
    await reopened.disconnect();
    final disconnected = TmdbSettings();
    await disconnected.boot();
    expect(disconnected.enabled, isFalse);
    expect(disconnected.apiKey, isEmpty);
    expect(disconnected.apiProxy, isEmpty);
    expect(disconnected.imageProxy, isEmpty);
    root.deleteSync(recursive: true);
  });
  test('代理拼接兼容省略协议、路径前缀及已有3，图片单独拼接', () {
    final settings = TmdbSettings()
      ..apiKey = 'fixture-key'
      ..apiProxy = 'proxy.test/base/3/'
      ..imageProxy = 'https://images.test/t/p/';
    expect(
      settings.apiUri('configuration').toString(),
      'https://proxy.test/base/3/configuration?api_key=fixture-key',
    );
    expect(
      settings.imageUrl('/poster.jpg'),
      'https://images.test/t/p/w500/poster.jpg',
    );
    settings.apiProxy = '';
    settings.imageProxy = '';
    expect(settings.apiUri('configuration').host, 'api.themoviedb.org');
    expect(Uri.parse(settings.imageUrl('/x.jpg')).host, 'image.tmdb.org');
  });
  http.Response json(Map<String, dynamic> value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  MockClient transport(List<Uri> requests) => MockClient((request) async {
    requests.add(request.url);
    if (request.url.path.endsWith('/configuration')) {
      return json({'images': {}});
    }
    if (request.url.path.endsWith('/search/multi')) {
      return json({
        'results': [
          {'id': 7, 'media_type': 'movie', 'title': '影片', 'overview': 'TMDB简介'},
        ],
      });
    }
    return json({
      'posters': [
        {'file_path': '/zero.jpg'},
        {'file_path': '/one.jpg'},
        {'file_path': '/two.jpg'},
      ],
    });
  });
  test('海报保留API数组顺序，不改排，简介与图片代理来自当前配置', () async {
    final settings = TmdbSettings()
      ..enabled = true
      ..apiKey = 'fixture-key'
      ..imageProxy = 'images.test/t/p';
    final requests = <Uri>[];
    final client = TmdbClient(settings, client: transport(requests));
    final result = await client.lookup('影片');
    expect(result?.overview, 'TMDB简介');
    expect(result?.posters.first, 'https://images.test/t/p/w500/zero.jpg');
    expect(result?.posters.length, 3);
    expect(
      requests.every((url) => url.queryParameters['api_key'] == 'fixture-key'),
      isTrue,
    );
    client.dispose();
  });
  test('未匹配条目或请求失败时回退，不误选不相干作品', () async {
    final settings = TmdbSettings()
      ..enabled = true
      ..apiKey = 'fixture-key';
    final client = TmdbClient(settings, client: transport([]));
    expect(await client.lookup('无关作品'), isNull);
    client.dispose();
    final failed = TmdbClient(
      settings,
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );
    expect(await failed.lookup('影片'), isNull);
    failed.dispose();
  });
  test('关闭会使在途请求作废，并阻止后续图片清单请求', () async {
    final settings = TmdbSettings()
      ..enabled = true
      ..apiKey = 'fixture-key';
    final pending = Completer<http.Response>();
    var calls = 0;
    final client = TmdbClient(
      settings,
      client: MockClient((_) async {
        calls++;
        return pending.future;
      }),
    );
    final lookup = client.lookup('影片');
    await Future<void>.delayed(Duration.zero);
    settings.enabled = false;
    await settings.save();
    pending.complete(
      json({
        'results': [
          {'id': 7, 'media_type': 'movie', 'title': '影片'},
        ],
      }),
    );
    expect(await lookup, isNull);
    expect(calls, 1);
    expect(await client.lookup('影片'), isNull);
    expect(calls, 1);
    client.dispose();
  });
  for (final style in TmdbPosterStyle.values) {
    testWidgets('海报模式 $style：固定首张、随机固定本次选择、轮播自动前进', (tester) async {
      final settings = TmdbSettings()
        ..enabled = true
        ..apiKey = 'fixture-key'
        ..posterStyle = style;
      final controller = TmdbDetailController(
        '影片',
        settings: settings,
        client: TmdbClient(settings, client: transport([])),
      );
      await tester.pump();
      await tester.pump();
      expect(controller.metadata?.posters.length, 3);
      if (style == TmdbPosterStyle.fixed) expect(controller.index, 0);
      final initial = controller.index;
      await tester.pump(const Duration(seconds: 4));
      expect(
        controller.index,
        style == TmdbPosterStyle.carousel ? (initial + 1) % 3 : initial,
      );
      settings.enabled = false;
      await settings.save();
      expect(controller.metadata, isNull);
      controller.dispose();
    });
  }
}
