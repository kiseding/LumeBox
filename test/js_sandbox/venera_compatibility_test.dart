import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/net/lume_net.dart';

import 'support/js_sandbox_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = installBridge() ? null : 'QuickJS 原生桥不可用';
  late Directory root;
  setUp(() async {
    enableEngineOnThisPlatform();
    root = Directory.systemTemp.createTempSync('venera-compat');
    await installTempSectionRoot(root);
  });
  tearDown(() async {
    LumeNet.closeSharedClientForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });

  test('官方二进制编码与同步摘要、HMAC 使用标准向量', () async {
    final engine = await openEngine(
      sourceId: 'venera-crypto',
      section: Section.comic,
      script: r'''
class CryptoFixture extends ComicSource {
  key = 'crypto-fixture'; name = 'Crypto'; version = '1';
  probe() {
    const bytes = Convert.encodeUtf8('abc');
    const binary = new Uint8Array([0, 255, 128, 65]).buffer;
    return {
      binary: bytes instanceof ArrayBuffer,
      md5: Convert.hexEncode(Convert.md5(bytes)),
      sha1: Convert.hexEncode(Convert.sha1(bytes)),
      sha256: Convert.hexEncode(Convert.sha256(bytes)),
      hmac: Convert.hmacString(Convert.encodeUtf8('key'), Convert.encodeUtf8('The quick brown fox jumps over the lazy dog'), 'sha256'),
      roundtrip: Convert.hexEncode(Convert.decodeBase64(Convert.encodeBase64(binary))),
      utf8: Convert.decodeUtf8(Convert.encodeUtf8('漫画😀'))
    };
  }
}
''',
    );
    addTearDown(engine.dispose);
    final result = await engine.callResult('probe');
    expect(result.isOk, isTrue, reason: result.error?.message);
    final value = result.value as Map;
    expect(value['binary'], true);
    expect(value['md5'], '900150983cd24fb0d6963f7d28e17f72');
    expect(value['sha1'], 'a9993e364706816aba3e25717850c26c9cd0d89d');
    expect(
      value['sha256'],
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      value['hmac'],
      'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
    );
    expect(value['roundtrip'], '00ff8041');
    expect(value['utf8'], '漫画😀');
  }, skip: skip);

  test('多模块首页封面与分类筛选映射到真实 Venera 参数', () async {
    final engine = await openEngine(
      sourceId: 'venera-facets',
      section: Section.comic,
      script: r'''
class FacetFixture extends ComicSource {
  key = 'facet-fixture'; name = 'Facets'; version = '1';
  explore = [{title: '推荐', type: 'multiPartPage', load: async (page) => {
    if (page !== null) throw new Error('multiPartPage 必须接收 null');
    return [{title: '最新', comics: [{id:'1', title:'封面', cover:'https://img.example/a.jpg'}]}];
  }}];
  category = {parts: [{categories: ['全部'], groupParam: 'all'}]};
  categoryComics = {
    optionList: [{label: '排序', options: ['new-最新', 'hot-热门']}],
    load: async (category, param, options, page) => ({comics: [{id: '2', title: param + ':' + options[0]}], maxPage: 3})
  };
}
''',
    );
    addTearDown(engine.dispose);
    final home = await engine.callResult('home');
    expect(home.isOk, true, reason: home.error?.message);
    final boards = (home.value as Map)['boards'] as List;
    expect((boards.first as Map)['title'], '最新');
    expect(
      (((boards.first as Map)['items'] as List).first as Map)['cover'],
      'https://img.example/a.jpg',
    );
    final filters = await engine.callResult('filters');
    expect(((filters.value as List).first as Map)['title'], '排序');
    final list = await engine.callResult('list', {
      'categoryId': 'category:0:0',
      'page': 1,
      'filters': {'venera:0': 'hot'},
    });
    expect(list.isOk, true, reason: list.error?.message);
    expect(
      (((list.value as Map)['items'] as List).first as Map)['title'],
      'all:hot',
    );
    final explore = await engine.callResult('list', {
      'categoryId': 'explore:0',
    });
    expect(((explore.value as Map)['items'] as List), hasLength(1));
  }, skip: skip);

  test('官方 comic 对象与图片钩子保留封面和章节的独立请求头', () async {
    final engine = await openEngine(
      sourceId: 'venera-image-headers',
      section: Section.comic,
      script: r'''
class ImageFixture extends ComicSource {
  key = 'image-fixture'; name = 'Images'; version = '1';
  explore = [{title:'推荐', load:async()=>({comics:[new Comic({id:'1',title:'作品',cover:'https://img.example/cover.jpg'})]})}];
  comic = {
    loadInfo: async()=>new ComicDetails({title:'作品', cover:'https://img.example/cover.jpg', chapters:{ep:'第一话'}}),
    loadEp: async()=>({images:['https://img.example/page.jpg']}),
    onThumbnailLoad: url=>new ImageLoadingConfig({url:url,headers:{Referer:'https://site.example/'}}),
    onImageLoad: (url,id,ep)=>new ImageLoadingConfig({url:url,headers:{Referer:'https://site.example/'+id+'/'+ep,Cookie:'image=ok'}})
  };
}
''',
    );
    addTearDown(engine.dispose);
    final list = await engine.callResult('list');
    expect(list.isOk, true, reason: list.error?.message);
    final item = (((list.value as Map)['items'] as List).first as Map);
    expect((item['coverHeaders'] as Map)['Referer'], 'https://site.example/');
    final detail = await engine.callResult('detail', {'id': '1'});
    expect(detail.isOk, true, reason: detail.error?.message);
    expect(
      ((detail.value as Map)['coverHeaders'] as Map)['Referer'],
      'https://site.example/',
    );
    final content = await engine.callResult('content', {
      'id': '1',
      'chapterId': 'ep',
    });
    expect(content.isOk, true, reason: content.error?.message);
    final headers =
        ((content.value as Map)['imageHeaders']
                as Map)['https://img.example/page.jpg']
            as Map;
    expect(headers['Referer'], 'https://site.example/1/ep');
    expect(headers['Cookie'], 'image=ok');
  }, skip: skip);

  test('Network.fetchBytes 保留非 UTF8 字节并支持官方方法签名', () async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final bytes = await request.fold<List<int>>(
        [],
        (all, part) => all..addAll(part),
      );
      expect(bytes, [0, 255, 128, 65]);
      expect(request.headers.value('referer'), 'https://comic.example/');
      request.response.add(bytes);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/image';
    final engine = await openEngine(
      sourceId: 'venera-bytes',
      section: Section.comic,
      script:
          '''
class BytesFixture extends ComicSource {
  key = 'bytes-fixture'; name = 'Bytes'; version = '1';
  async probe() {
    const bytes = new Uint8Array([77, 0, 255, 128, 65, 88]).subarray(1, 5);
    const result = await Network.fetchBytes('POST', '$url', {'Referer':'https://comic.example/'}, bytes);
    const posted = await Network.post('$url', {'Referer':'https://comic.example/'}, bytes);
    return {status: result.status, bytes: Convert.hexEncode(result.body), binary: result.body instanceof ArrayBuffer, posted: posted.status};
  }
}
''',
    );
    addTearDown(engine.dispose);
    final result = await engine.callResult('probe');
    expect(result.isOk, true, reason: result.error?.message);
    expect((result.value as Map)['status'], 200);
    expect((result.value as Map)['bytes'], '00ff8041');
    expect((result.value as Map)['binary'], true);
    expect((result.value as Map)['posted'], 200);
  }, skip: skip);
}
