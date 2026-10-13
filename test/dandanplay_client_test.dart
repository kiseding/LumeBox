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
    await expectLater(client.search('作品'), throwsStateError);
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
}
