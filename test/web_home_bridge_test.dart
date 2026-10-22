import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/web/web_home_bridge.dart';
import 'package:lume_box/core/web/web_home_import.dart';
import 'package:lume_box/core/web/web_home_playback.dart';
import 'package:lume_box/core/web/web_home_sdk.dart';
import 'package:lume_box/core/web/web_home_sources.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  late WebHomeBridge bridge;
  late List<http.Request> requests;
  late List<Map<String, dynamic>> plays, pans, chrome;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('web-home-bridge');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    library = await ReadingLibrary.open(Section.video);
    requests = [];
    plays = [];
    pans = [];
    chrome = [];
    bridge = WebHomeBridge(
      sourceId: 'test',
      library: library,
      onPlay: (args) async => plays.add(args),
      onPan: (args) async => pans.add(args),
      onChrome: (args) async => chrome.add(args),
      http: LumeHttp(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/denied') {
            return http.Response('denied', 403);
          }
          if (request.url.path == '/image') {
            return http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          if (request.url.path == '/html') {
            return http.Response(
              '<script>bad()</script>',
              200,
              headers: {'content-type': 'text/html'},
            );
          }
          return http.Response(
            '{"title":"直播"}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
  });
  tearDown(() async {
    await bridge.close();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('导入 HTML 保存正文，编辑名称和重新开库后仍可恢复', () async {
    final html = WebHomeImport.decode(
      utf8.encode(
        '<!doctype html><html><head><title>测试 &amp; 直播</title></head></html>',
      ),
    );
    expect(WebHomeImport.name(html, 'input.html'), '测试 & 直播');
    final store = WebHomeStore.forLibrary(library);
    store.upsert(WebHomeSource(id: 'local', name: '测试', url: '', html: html));
    store.upsert(store.items.single.copyWith(name: '改名'));
    final decoded = WebHomeSource.fromJson(
      jsonDecode(library.setting('video.web.homes.v1')!).single,
    )!;
    expect(decoded.html, html);
    expect(decoded.isLocal, isTrue);
    expect(decoded.name, '改名');
    library.dispose();
    library = await ReadingLibrary.open(Section.video);
    expect(WebHomeStore.forLibrary(library).items.single, decoded);
  });

  test('导入拒绝脚本、无效编码和超限文件，接受 UTF-8 BOM', () {
    expect(
      () => WebHomeImport.decode(utf8.encode('console.log(1)')),
      throwsFormatException,
    );
    expect(() => WebHomeImport.decode([255, 255]), throwsFormatException);
    expect(
      () => WebHomeImport.decode(List.filled(WebHomeImport.maxBytes + 1, 32)),
      throwsFormatException,
    );
    expect(
      WebHomeImport.decode([239, 187, 191, ...utf8.encode('<html></html>')]),
      contains('<html>'),
    );
  });

  test('SDK 在作者脚本之前注入，缓存文本不能结束 script 标签', () {
    final doc = injectWebHomeSdk(
      '<!doctype html><html><head><script>author()</script></head></html>',
      'http://127.0.0.1/test',
      storage: {'value': '</script><script>bad()</script>'},
    );
    expect(doc.indexOf('window.fm=fm'), lessThan(doc.indexOf('author()')));
    expect(doc, isNot(contains('</script><script>bad()')));
  });

  test('原生请求保留方法、请求头、正文并支持 JSON 响应', () async {
    final value = await bridge.dispatch('req', {
      'url': 'https://site.test/api',
      'options': {
        'method': 'POST',
        'headers': {'Referer': 'https://site.test/', 'User-Agent': 'custom-UA'},
        'body': '{"page":1}',
        'responseType': 'json',
      },
    }) as Map;
    expect(value['ok'], isTrue);
    expect((value['body'] as Map)['title'], '直播');
    expect(requests.single.method, 'POST');
    expect(requests.single.body, '{"page":1}');
    expect(requests.single.headers['Referer'], 'https://site.test/');
    expect(requests.single.headers['User-Agent'], 'custom-UA');
  });

  test('HTTP 403 保留业务状态，无效协议不产生网络请求', () async {
    final denied = await bridge.dispatch('req', {
      'url': 'https://site.test/denied',
    }) as Map;
    expect(denied['status'], 403);
    expect(denied['ok'], isFalse);
    expect(denied['body'], 'denied');
    final invalid =
        await bridge.dispatch('req', {'url': 'file:///private/token'}) as Map;
    expect(invalid['ok'], isFalse);
    expect(requests, hasLength(1));
  });

  test('缓存按页面及命名空间隔离，删除主页清除对应缓存', () async {
    await bridge.dispatch('cache.set', {
      'key': 'prefs',
      'space': 'a',
      'value': 'first',
    });
    await bridge.dispatch('cache.set', {
      'key': 'prefs',
      'space': 'b',
      'value': 'second',
    });
    expect(
      await bridge.dispatch('cache.get', {'key': 'prefs', 'space': 'a'}),
      'first',
    );
    expect(
      await bridge.dispatch('cache.get', {'key': 'prefs', 'space': 'b'}),
      'second',
    );
    final other = WebHomeBridge(
      sourceId: 'other',
      library: library,
      onPlay: (_) async {},
      onPan: (_) async {},
      onChrome: (_) async {},
    );
    expect(
      await other.dispatch('cache.get', {'key': 'prefs', 'space': 'a'}),
      isNull,
    );
    await other.close();
    WebHomeStore.forLibrary(library).remove('test');
    expect(
      await bridge.dispatch('cache.get', {'key': 'prefs', 'space': 'a'}),
      isNull,
    );
  });

  test('播放携带防盗链头，分享和磁力链接不直接进入媒体解码器', () {
    final live = WebHomePlayback({
      'url': 'https://live.test/stream.flv',
      'title': '直播',
      'options': {
        'headers': {'Referer': 'https://site.test/', 'User-Agent': 'UA'},
      },
    });
    expect(live.media.headers!['Referer'], 'https://site.test/');
    for (final url in [
      'push://https://pan.quark.cn/s/abc',
      'https://pan.quark.cn/s/abc',
      'magnet:?xt=urn:btih:abc',
    ]) {
      final share = WebHomePlayback({'url': url});
      expect(share.isShare, isTrue);
      expect(() => share.media, throwsFormatException);
    }
    expect(
      () => WebHomePlayback({'url': 'file:///private/file'}).media,
      throwsFormatException,
    );
  });

  test('本地 HTTP 服务校验随机路径与 Origin，资源接口不代理可执行 HTML', () async {
    final home = await bridge.start(
      '<html><head></head><body>测试</body></html>',
    );
    final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(),
      _RealHttpOverrides(),
    )..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
    final page = await (await client.getUrl(home)).close();
    expect(await utf8.decoder.bind(page).join(), contains('window.fm=fm'));
    await bridge.dispatch('storage.set', {'key': 'theme', 'value': 'blue'});
    final refreshed = await (await client.getUrl(home)).close();
    expect(
      await utf8.decoder.bind(refreshed).join(),
      contains('"theme":"blue"'),
    );
    await bridge.dispatch('storage.clear', {});
    final cleared = await (await client.getUrl(home)).close();
    expect(
      await utf8.decoder.bind(cleared).join(),
      isNot(contains('"theme":"blue"')),
    );
    final wrong = await (await client.getUrl(
      home.replace(path: '/wrong/index.html'),
    )).close();
    expect(wrong.statusCode, 403);
    await wrong.drain<void>();
    final foreign = await client.postUrl(home.resolve('call'));
    foreign.headers.set('Origin', 'https://evil.test');
    foreign.write('{}');
    final denied = await foreign.close();
    expect(denied.statusCode, 403);
    await denied.drain<void>();
    final resource = home
        .resolve('res')
        .replace(
          queryParameters: {
            'data': jsonEncode({'url': 'https://site.test/html'}),
          },
        );
    final blocked = await (await client.getUrl(resource)).close();
    expect(blocked.statusCode, 415);
    await blocked.drain<void>();
    final image = home
        .resolve('res')
        .replace(
          queryParameters: {
            'data': jsonEncode({
              'url': 'https://site.test/image',
              'options': {
                'headers': {'Referer': 'https://site.test/'},
              },
            }),
          },
        );
    final served = await (await client.getUrl(image)).close();
    expect(served.statusCode, 200);
    expect(await served.expand((bytes) => bytes).toList(), [1, 2, 3]);
    expect(requests.last.headers['Referer'], 'https://site.test/');
  });

  test('真实 JavaScript SDK 经 HTTP 调用请求、缓存、直播解析及网盘分发', () async {
    final home = await bridge.start('<html><head></head></html>');
    final sdk = webHomeSdk(
      home.resolve('.').toString().replaceFirst(RegExp(r'/$'), ''),
    );
    final script = File('${root.path}/sdk-test.cjs');
    await script.writeAsString('''
const assert=require('node:assert/strict');
global.window=global;
global.document={documentElement:{classList:{add(){}}}};
global.dispatchEvent=()=>{};
${sdk.substring(8, sdk.length - 9)}
(async()=>{
 const result=await fm.req('https://site.test/api',{responseType:'json'});
 assert.equal(result.body.title,'直播');
 await fm.cache.set('history','saved','livecombo');
 assert.equal(await fm.cache.get('history','livecombo'),'saved');
 localStorage.setItem('theme','blue');
 assert.equal(localStorage.getItem('theme'),'blue');
 window.__fmWebHomeInlineResolver=async()=>({url:'https://live.test/1.flv',headers:{Referer:'https://live.test/'}});
 await fm.vodInline({vod_name:'测试直播',episodes:[{name:'FLV',url:'old'}]});
 await fm.pan.play({url:'https://pan.quark.cn/s/abc',password:'1234',title:'网盘'});
 await fm.ui.setChrome({mode:'edge'});
 assert.equal(fm.ui.getViewport().chromeMode,'edge');
 const config=await fm.config();assert.equal(config.driveCheck,false);
 const health=await fm.pan.check([{}]);assert.equal(health.results[0].state,'uncertain');
 assert.ok(fm.res('https://site.test/image',{headers:{Referer:'https://site.test/'}}).includes('/res?data='));
 console.log('SDK integration passed');
})().catch(e=>{console.error(e);process.exitCode=1;});
''');
    final result = await Process.run('node', [script.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(plays.single['url'], 'https://live.test/1.flv');
    expect((plays.single['options'] as Map)['headers'], {
      'Referer': 'https://live.test/',
    });
    expect(pans.single['password'], '1234');
    expect(chrome.single['mode'], 'edge');
    expect(library.setting('video.web.cache.test'), contains('blue'));
  });
}
