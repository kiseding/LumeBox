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
  test('TMDB v4 Token 放在 Bearer 请求头，v3 Key 仍使用 api_key', () async {
    for (final credential in [
      'eyJfixture.payload.signature',
      'Bearer eyJfixture.payload.signature',
      'fixture-v3-key',
    ]) {
      final settings = TmdbSettings()
        ..enabled = true
        ..apiKey = credential;
      final client = TmdbClient(
        settings,
        client: MockClient((request) async {
          if (settings.usesBearer) {
            expect(
              request.headers['Authorization'],
              'Bearer eyJfixture.payload.signature',
            );
            expect(request.url.queryParameters.containsKey('api_key'), false);
          } else {
            expect(request.headers.containsKey('Authorization'), false);
            expect(request.url.queryParameters['api_key'], 'fixture-v3-key');
          }
          return http.Response('{"images":{}}', 200);
        }),
      );
      await client.testApi();
      client.dispose();
    }
  });
  test('推荐使用匹配影片类型，过滤自身和重复条目并保留缓存', () async {
    final settings = TmdbSettings()
      ..enabled = true
      ..apiKey = 'fixture-key';
    final client = TmdbClient(
      settings,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          return http.Response(
            jsonEncode({
              'results': [
                {'id': 7, 'media_type': 'tv', 'name': '测试剧'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path.endsWith('/tv/7')) {
          expect(
            request.url.queryParameters['append_to_response'],
            contains('recommendations'),
          );
          return http.Response(
            jsonEncode({
              'recommendations': {
                'results': [
                  {'id': 7, 'name': '测试剧'},
                  {'id': 8, 'name': '相似剧', 'poster_path': '/similar.jpg'},
                  {'id': 8, 'name': '相似剧'},
                  {'id': 9, 'name': ''},
                  {'id': 10, 'name': '成人条目', 'adult': true},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 200);
      }),
    );
    final result = (await client.lookup('测试剧'))!;
    expect(result.recommendations.length, 1);
    expect(result.recommendations.single.title, '相似剧');
    expect(result.recommendations.single.poster, contains('/w500/similar.jpg'));
    expect(
      TmdbMetadata.fromJson(result.toJson()).recommendations.single.title,
      '相似剧',
    );
    expect((await client.lookup('测试剧'))!.recommendations.single.title, '相似剧');
    client.dispose();
  });
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
  test('五类图片尺寸独立保存，代理路径正确，尺寸变化隔离旧缓存', () async {
    final root = Directory.systemTemp.createTempSync('tmdb-image-sizes-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    try {
      final settings = TmdbSettings();
      await settings.boot();
      expect(TmdbImageKind.values.map(settings.imageSize), [
        'w1280',
        'w500',
        'w500',
        'w185',
        'w300',
      ]);
      settings.imageProxy = 'https://images.test/custom/t/p/';
      final oldCache = settings.cacheKey('影片');
      for (final kind in TmdbImageKind.values) {
        for (final size in kind.sizes) {
          settings.setImageSize(kind, size);
          expect(
            settings.imageUrl('/image.jpg', kind: kind),
            'https://images.test/custom/t/p/$size/image.jpg',
          );
        }
      }
      expect(settings.cacheKey('影片'), isNot(oldCache));
      await settings.save();
      final reopened = TmdbSettings();
      await reopened.boot();
      for (final kind in TmdbImageKind.values) {
        expect(reopened.imageSize(kind), kind.sizes.last);
      }
      expect(
        () => reopened.setImageSize(TmdbImageKind.logo, 'w780'),
        throwsArgumentError,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
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
  test('详情标题回退：列表标题未命中时用备用标题重新匹配', () async {
    final settings = TmdbSettings()
      ..enabled = true
      ..apiKey = 'fixture-key';
    final queries = <String>[];
    final client = TmdbClient(
      settings,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/search/multi')) {
          final query = request.url.queryParameters['query'] ?? '';
          queries.add(query);
          return json({
            'results': query == '正确标题'
                ? [
                    {'id': 7, 'media_type': 'movie', 'title': '正确标题'},
                  ]
                : <Map<String, Object?>>[],
          });
        }
        if (request.url.path.endsWith('/movie/7')) {
          return json({
            'title': '正确标题',
            'overview': '来自详情标题的 TMDB 简介',
            'posters': [
              {'file_path': '/poster.jpg'},
            ],
          });
        }
        return json(<String, Object?>{});
      }),
    );
    final controller = TmdbDetailController(
      '猫源列表标题',
      settings: settings,
      client: client,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.metadata, isNull);
    expect(queries, contains('猫源列表标题'));

    controller.updateTitles(<String>['正确标题', '猫源列表标题']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.metadata?.overview, '来自详情标题的 TMDB 简介');
    expect(queries, contains('正确标题'));
    controller.dispose();
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
