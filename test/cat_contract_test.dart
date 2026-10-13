import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CatService service;
  late HttpServer remote;
  late HttpServer node;
  late Uri remoteBase, nodeBase;
  Map<String, dynamic>? runtime;
  final secrets = <String, String>{};
  var starts = 0;
  var index = 'module.exports={start:async()=>{}}';
  var advertised = '';
  var failDownload = false;
  Future<Map<String, dynamic>> bridge(
    String action,
    Map<String, dynamic> opt, {
    String? id,
  }) async {
    final spec = runtime!;
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${spec['bridgePort']}/msg'),
      );
      req.headers.contentType = ContentType.json;
      req.headers.set('x-catvod-token', spec['token']);
      if (id != null) req.headers.set('x-lume-cat-source', id);
      req.write(jsonEncode({'action': action, 'opt': opt}));
      final response = await req.close();
      return catMap(jsonDecode(await utf8.decoder.bind(response).join()));
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    HttpOverrides.global =
        null; // These contract tests use only loopback fixture servers.
    root = Directory.systemTemp.createTempSync('cat-contract');
    secrets.clear();
    starts = 0;
    runtime = null;
    failDownload = false;
    index = 'module.exports={start:async()=>{}}';
    advertised = md5.convert(utf8.encode(index)).toString();
    remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    remoteBase = Uri.parse('http://127.0.0.1:${remote.port}');
    remote.listen((req) async {
      final path = req.uri.path;
      if (failDownload) {
        req.response.statusCode = 503;
      } else if (path.endsWith('.config.js.md5')) {
        req.response.statusCode = 404;
      } else if (path.endsWith('.js.md5')) {
        req.response.write(advertised);
      } else if (path.endsWith('.config.js')) {
        req.response.write('module.exports={video:{sites:[]}}');
      } else {
        req.response.write(index);
      }
      await req.response.close();
    });
    node = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    nodeBase = Uri.parse('http://127.0.0.1:${node.port}');
    node.listen((req) async {
      final body = catMap(
        jsonDecode(
          await utf8.decoder.bind(req).join().then((s) => s.isEmpty ? '{}' : s),
        ),
      );
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/ctl/source') {
        await bridge('sourceStarted', {
          'id': body['id'],
          'address': nodeBase.toString(),
        });
        req.response.write('{}');
      } else if (req.uri.path == '/website') {
        req.response.write(
          '{}',
        ); // JSON placeholder must not be treated as the config page.
      } else if (req.uri.path == '/website/index.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html>网盘登录</html>');
      } else if (req.uri.path == '/config') {
        req.response.write(
          jsonEncode({
            'video': {
              'sites': [
                {'key': 'nodejs_demo', 'name': '测试站点', 'type': 3},
                {'key': 'disabled', 'name': '禁用', 'enable': false},
              ],
            },
          }),
        );
      } else if (req.uri.path.endsWith('/home')) {
        req.response.write(
          jsonEncode({
            'class': [
              {'type_id': 'movie', 'type_name': '电影'},
            ],
            'filters': {
              'movie': [
                {
                  'key': 'area',
                  'name': '地区',
                  'value': [
                    {'n': '全部', 'v': ''},
                    {'n': '国产', 'v': 'cn'},
                  ],
                },
              ],
            },
          }),
        );
      } else if (req.uri.path.endsWith('/category')) {
        req.response.write(
          jsonEncode({
            'list': [
              {'vod_id': 'same', 'vod_name': '影片', 'vod_pic': '/poster.jpg'},
            ],
            'pagecount': 2,
          }),
        );
      } else {
        req.response.write('{}');
      }
      await req.response.close();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CatService.channel, (call) async {
          final args = catMap(call.arguments);
          if (call.method == 'readSecret') return secrets[args['key']];
          if (call.method == 'writeSecret') {
            if (args['value'] == null) {
              secrets.remove(args['key']);
            } else {
              secrets[args['key']] = args['value'];
            }
          }
          if (call.method == 'isSupported') return true;
          if (call.method == 'start') {
            starts++;
            runtime = catMap(
              jsonDecode(await File(args['spec']).readAsString()),
            );
            await bridge('controlReady', {'address': nodeBase.toString()});
            final source = catMaps(runtime!['sources']).first;
            await bridge('sourceStarted', {
              'id': source['id'],
              'address': nodeBase.toString(),
            });
            return true;
          }
          return null;
        });
    service = CatService.testing();
  });
  tearDown(() async {
    await service.closeForTesting();
    await remote.close(force: true);
    await node.close(force: true);
    root.deleteSync(recursive: true);
  });
  test('站点列数独立保存并在重启后恢复', () async {
    await service.boot();
    await service.setSiteColumns(3);
    final restored = CatService.testing();
    await restored.boot();
    expect(restored.siteColumns, 3);
    await restored.setSiteColumns(99);
    expect(restored.siteColumns, 3);
    await restored.closeForTesting();
  });
  test('订阅持久化、校验失败保留旧包、首次失败仍保留链接供重试', () async {
    final record = await service.add(
      '包',
      remoteBase.resolve('/index.js.md5').toString(),
    );
    final old = record.hash;
    index = 'corrupt';
    advertised = '00000000000000000000000000000000';
    await expectLater(service.update(record), throwsFormatException);
    expect(record.hash, old);
    expect(record.error, contains('MD5'));
    failDownload = true;
    await expectLater(
      service.add('稍后重试', remoteBase.resolve('/other.js.md5').toString()),
      throwsA(isA<HttpException>()),
    );
    expect(service.subscriptions.length, 2);
    final stored = catMap(
      jsonDecode(
        await File('${root.path}/sections/cat/node/subscriptions.json')
            .readAsString(),
      ),
    );
    expect(
      catMaps(stored['subscriptions']).last['url'],
      endsWith('/other.js.md5'),
    );
  });
  test('一次 Node 启动、多订阅账号隔离、真实配置页探测和筛选映射', () async {
    final first = await service.add(
      '一',
      remoteBase
          .resolve('/one.js.md5')
          .replace(userInfo: 'user:password')
          .toString(),
    );
    final second = await service.add(
      '二',
      remoteBase.resolve('/two.js.md5').toString(),
    );
    expect(first.id, isNot(second.id));
    expect(first.hash, second.hash);
    await service.activate(first);
    await service.activate(second);
    expect(starts, 1);
    expect(first.sites.single.key, 'demo');
    await bridge('saveProfile', {'cookie': 'account-one'}, id: first.id);
    await bridge('saveProfile', {'cookie': 'account-two'}, id: second.id);
    expect(
      (await bridge('queryProfile', {}, id: first.id))['cookie'],
      'account-one',
    );
    expect(
      (await bridge('queryProfile', {}, id: second.id))['cookie'],
      'account-two',
    );
    await bridge('saveProfile', {}, id: second.id);
    expect(
      await bridge('queryProfile', {}, id: second.id),
      isEmpty,
      reason: '退出账号不能重新恢复已删除的凭证',
    );
    final page = await service.configurationUrl(second);
    expect(page.path, '/website/index.html');
    final source = CatDataSource(service, first.sites.single);
    expect(
      (await source.filtersFor(categoryId: 'movie')).single.options.last.id,
      'cn',
    );
    final list = await source.list(categoryId: 'movie');
    expect(list.hasMore, true);
    expect(source.rawItemId(list.items.single.id), 'same');
    expect(list.items.single.cover, nodeBase.resolve('/poster.jpg').toString());
    final stored = await File(
      '${root.path}/sections/cat/node/subscriptions.json',
    ).readAsString();
    expect(stored, isNot(contains('password')));
    expect(stored, isNot(contains('account-one')));
  });
  test('播放线路先分隔后还原网址，集数与站点身份不串', () {
    final configured = CatSite.fromJson('config', {
      'key': 'nodejs_configured',
      'name': '有配置的站点',
      'api': 'http://127.0.0.1:9988/spider/configured/3?mode=local',
      'ext': {
        'headers': {'User-Agent': 'fixture'},
        'enabled': true,
      },
    });
    expect(configured.ext, isA<Map>());
    expect(configured.api, '/spider/configured/3?mode=local');
    expect(CatSite.fromJson('config', configured.toJson()).ext, configured.ext);
    final chapters = CatDataSource.parseChapters({
      'vod_play_from': '线路一',
      'vod_play_url':
          '第一集\$https://video.test/a?token=a＃b＄c#第二集\$https://video.test/b',
    });
    expect(chapters.length, 2);
    expect(
      catMap(jsonDecode(chapters.first.id))['id'],
      'https://video.test/a?token=a#b\$c',
    );
    final a = CatSite(
      subscriptionId: 'a',
      key: 'same',
      name: 'A',
      api: '/spider/same/3',
    );
    final b = CatSite(
      subscriptionId: 'b',
      key: 'same',
      name: 'B',
      api: '/spider/same/3',
    );
    expect(
      CatDataSource(service, a).item({'vod_id': '1', 'vod_name': 'A'})!.id,
      isNot(
        CatDataSource(service, b).item({'vod_id': '1', 'vod_name': 'B'})!.id,
      ),
    );
  });
}
