import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/features/video/danmaku/dandanplay_client.dart';
import 'package:lume_box/features/video/danmaku/danmaku_models.dart';

void main() {
  test('兼容部署保留路径前缀，官方凭证不发给第三方', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'example-id',
        'example-secret',
        baseUrl: 'https://danmu.example/token/',
      ),
      client: MockClient((request) async {
        expect(request.url.path, '/token/api/v2/search/episodes');
        expect(request.url.queryParameters['anime'], '半步多·沧澜传');
        expect(request.url.queryParameters['episode'], '1');
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-appsecret')),
        );
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-signature')),
        );
        return http.Response(
          jsonEncode({
            'success': true,
            'animes': [
              {
                'animeTitle': '半步多·沧澜传',
                'episodes': [
                  {'episodeId': 'platform-123', 'episodeTitle': '第1集'},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    final items = await client.search('半步多·沧澜传', episode: 1);
    expect(items.single.id, 'platform-123');
  });

  test('官方请求使用签名，密钥不随请求发送', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        final headers = {
          for (final entry in request.headers.entries)
            entry.key.toLowerCase(): entry.value,
        };
        expect(headers['x-appid'], 'sample');
        expect(headers['x-appsecret'], isNull);
        final data =
            'sample${headers['x-timestamp']}/api/v2/search/episodes'
            'secret';
        expect(
          headers['x-signature'],
          base64Encode(sha256.convert(utf8.encode(data)).bytes),
        );
        return http.Response('{"success":true,"animes":[]}', 200);
      }),
    );
    addTearDown(client.close);
    expect(await client.search('作品'), isEmpty);
  });

  test('官方缺少凭证时不发送无效网络请求', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        '',
        '',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((_) async {
        fail('缺少凭证不应联网');
      }),
    );
    addTearDown(client.close);
    await expectLater(client.search('作品'), throwsA(isA<DandanplayException>()));
  });

  test('弹幕时间按秒转毫秒，保留顶部底部颜色，忽略坏数据', () {
    final track = DandanplayClient.parseComments({
      'comments': [
        {'p': '12.34,5,16711680,user', 'm': '顶部'},
        {'p': '2.5,4,65280,user', 'm': '底部'},
        {'p': 'NaN,1,16777215,user', 'm': '坏数据'},
        {'p': '-1,1,16777215,user', 'm': '负时间'},
      ],
    });
    expect(track.length, 2);
    expect(track.items.first.time, const Duration(milliseconds: 2500));
    expect(track.items.first.mode, DanmakuMode.bottom);
    expect(track.items.first.color, 65280);
    expect(track.items.last.time, const Duration(milliseconds: 12340));
    expect(track.items.last.mode, DanmakuMode.top);
  });

  test('只自动选择唯一精确作品，不把相近作品弹幕混入', () {
    const exact = DandanplayEpisode(
      id: '1',
      title: '半步多·沧澜传(2026)【电视剧】from imgo',
      episode: '第1集',
    );
    const other = DandanplayEpisode(
      id: '2',
      title: '半步多·沧澜传第二季',
      episode: '第1集',
    );
    expect(DandanplayClient.exactMatch([exact, other], '半步多·沧澜传')?.id, '1');
    expect(DandanplayClient.exactMatch([other], '半步多·沧澜传'), isNull);
    expect(DandanplayClient.exactMatch([exact, exact], '半步多·沧澜传'), isNull);
  });

  test('签名前清理粘贴凭证的首尾空格，搜索清理年份与来源后缀', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        ' sample ',
        '\nsecret\n',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        expect(request.url.queryParameters['anime'], '作品');
        expect(request.headers['X-AppId'], 'sample');
        final data =
            'sample${request.headers['X-Timestamp']}${request.url.path}secret';
        expect(
          request.headers['X-Signature'],
          base64Encode(sha256.convert(utf8.encode(data)).bytes),
        );
        return http.Response('{"success":true,"animes":[]}', 200);
      }),
    );
    addTearDown(client.close);
    await client.search('作品(2026)【电视剧】 FROM qq');
  });

  test('官方弹幕 302 跳转 CDN 后解析弹幕，不转发鉴权头', () async {
    var requests = 0;
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        requests++;
        expect(request.followRedirects, isFalse);
        if (requests == 1) {
          expect(request.url.path, '/api/v2/comment/123450001');
          expect(request.url.queryParameters['withRelated'], 'true');
          expect(request.headers['X-Signature'], isNotEmpty);
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://comments.example/cached.json?token=cdn-token',
            },
          );
        }
        expect(request.url.host, 'comments.example');
        expect(request.url.queryParameters['token'], 'cdn-token');
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(
            anyOf(
              contains('x-appid'),
              contains('x-signature'),
              contains('x-timestamp'),
              contains('x-appsecret'),
            ),
          ),
        );
        return http.Response(
          jsonEncode({
            'comments': [
              {'p': '1.25,1,16777215,user', 'm': '弹幕'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    final track = await client.comments('123450001');
    expect(track.items.single.text, '弹幕');
    expect(track.items.single.time, const Duration(milliseconds: 1250));
    expect(requests, 2);
  });

  test('同官方主机跳转时用新路径重新签名', () async {
    var requests = 0;
    final client = DandanplayClient(
      credentials: const DandanplayCredentials(
        'sample',
        'secret',
        baseUrl: DandanplayCredentials.officialBase,
      ),
      client: MockClient((request) async {
        if (++requests == 1) {
          return http.Response(
            '',
            302,
            headers: {'location': '/cached/comments?format=json'},
          );
        }
        final data =
            'sample${request.headers['X-Timestamp']}/cached/comments'
            'secret';
        expect(
          request.headers['X-Signature'],
          base64Encode(sha256.convert(utf8.encode(data)).bytes),
        );
        return http.Response('{"comments":[]}', 200);
      }),
    );
    addTearDown(client.close);
    await client.comments('1');
    expect(requests, 2);
  });

  test('无效跳转与循环有限终止', () async {
    for (final location in [
      'http://comments.example/plain',
      'https://user:pass@comments.example/data',
      '/loop',
    ]) {
      var requests = 0;
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          'sample',
          'secret',
          baseUrl: DandanplayCredentials.officialBase,
        ),
        client: MockClient((_) async {
          requests++;
          return http.Response('', 302, headers: {'location': location});
        }),
      );
      await expectLater(
        client.comments('1'),
        throwsA(isA<DandanplayException>()),
      );
      expect(requests, lessThanOrEqualTo(6));
      client.close();
    }
  });

  for (final reason in {
    'Invalid Timestamp': '设备时间',
    'Invalid AppId': 'AppId 无效',
    'Invalid Signature': 'AppSecret 无效',
    'Missing Authentication Headers': '服务未收到',
  }.entries) {
    test('连接测试呈现官方鉴权原因：${reason.key}', () async {
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          'sample',
          'secret',
          baseUrl: DandanplayCredentials.officialBase,
        ),
        client: MockClient(
          (_) async =>
              http.Response('', 403, headers: {'x-error-message': reason.key}),
        ),
      );
      addTearDown(client.close);
      try {
        await client.checkConnection();
        fail('拒绝响应必须报错');
      } catch (error) {
        expect(DandanplayClient.describeError(error), contains(reason.value));
        expect(DandanplayClient.describeError(error), contains('HTTP 403'));
        expect(
          DandanplayClient.describeError(error),
          isNot(contains('secret')),
        );
      }
    });
  }

  test('连接测试区分业务失败、HTTP 失败和空搜索成功', () async {
    for (final status in [200, 429, 503]) {
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          '',
          '',
          baseUrl: 'http://localhost:1234/prefix',
        ),
        client: MockClient(
          (_) async => http.Response('{"success":false,"errorCode":1}', status),
        ),
      );
      await expectLater(
        client.checkConnection(),
        throwsA(isA<DandanplayException>()),
      );
      client.close();
    }
    final client = DandanplayClient(
      credentials: const DandanplayCredentials('', ''),
      client: MockClient(
        (_) async => http.Response('{"success":true,"animes":[]}', 200),
      ),
    );
    addTearDown(client.close);
    await client.checkConnection();
  });

  test('缺失列表的响应不能误报连接成功或本集零弹幕', () async {
    final client = DandanplayClient(
      credentials: const DandanplayCredentials('', ''),
      client: MockClient((_) async => http.Response('{"success":true}', 200)),
    );
    addTearDown(client.close);
    await expectLater(
      client.checkConnection(),
      throwsA(isA<DandanplayException>()),
    );
    await expectLater(
      client.comments('1'),
      throwsA(isA<DandanplayException>()),
    );
  });

  test('按章节名称而非多线路列表位置推断集数，手动搜索可省略集数', () async {
    expect(DandanplayClient.episodeNumber('第07集', chapterIndex: 1), 7);
    expect(DandanplayClient.episodeNumber('S02E03', chapterIndex: 14), 3);
    expect(DandanplayClient.episodeNumber('EP04', chapterIndex: 15), 4);
    expect(DandanplayClient.episodeNumber('03', chapterIndex: 20), 3);
    expect(DandanplayClient.episodeNumber('1080P高清', chapterIndex: 2), 1);
    expect(DandanplayClient.episodeNumber('未知', chapterIndex: 2), 3);
    final client = DandanplayClient(
      credentials: const DandanplayCredentials('', ''),
      client: MockClient((request) async {
        expect(request.url.queryParameters.containsKey('episode'), isFalse);
        return http.Response('{"animes":[]}', 200);
      }),
    );
    addTearDown(client.close);
    await client.search('作品');
  });
}
