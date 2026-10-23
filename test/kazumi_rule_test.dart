import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/net/source_import_input.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/source/kazumi_rule.dart';
import 'package:lume_box/core/source/source_package.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

const rule = {
  'api': '3',
  'name': 'Example',
  'version': '1',
  'baseURL': 'https://example.test/',
  'searchURL': 'https://example.test/search?q=@keyword',
  'searchList': '//article',
  'searchName': '//a',
  'searchResult': '//a',
  'chapterRoads': '//ul',
  'chapterResult': '//li/a',
  'usePost': true,
  'referer': 'https://example.test/',
  'userAgent': 'Example UA',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  if (available) enableEngineOnThisPlatform();
  test('JSON 文件与粘贴识别为视频源，更新沿用规则地址身份', () {
    final json = jsonEncode(rule);
    expect(SourceImportInput.classify(json).isScript, true);
    final first = SourcePackage.prepare(
      json,
      originUrl: 'https://rules.test/Example.json',
    );
    final second = SourcePackage.prepare(
      jsonEncode({...rule, 'version': '2', 'baseURL': 'https://mirror.test/'}),
      originUrl: 'https://rules.test/Example.json',
    );
    expect(SourceMetadata.parseHeader(first)!.category, 'video');
    expect(
      SourceMetadata.parseHeader(first)!.id,
      SourceMetadata.parseHeader(second)!.id,
    );
    expect(SourceMetadata.parseHeader(second)!.version, '2');
    expect(
      () => KazumiRule.convert(jsonEncode({...rule, 'deprecated': true})),
      throwsFormatException,
    );
    expect(
      () => KazumiRule.convert(jsonEncode({...rule, 'api': '99'})),
      throwsFormatException,
    );
  });

  test('索引订阅跳过失效规则，保留每个 JSON 的更新地址', () async {
    const origin = 'https://rules.test/index.json';
    final files = {
      origin: jsonEncode([
        {'name': 'Example', 'version': '1', 'useNativePlayer': true},
        {'name': 'Gone', 'version': '1', 'useNativePlayer': true},
      ]),
      'https://rules.test/Example.json': jsonEncode(rule),
    };
    final failures = <String>[];
    final subscription = SourceSubscription(
      fetch: (url) async {
        final text = files[url];
        if (text == null) throw StateError('HTTP 404');
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
      onSkip: (url, _) => failures.add(url),
    );
    final refs = await subscription.resolveRefs([origin]);
    expect(refs.single.url, 'https://rules.test/Example.json');
    expect(SourceMetadata.parseHeader(refs.single.script)!.name, 'Example');
    expect(subscription.complete, false);
    expect(failures, ['https://rules.test/Gone.json']);
  });

  test('真实 JS 引擎搜索发送 POST 与请求头，未捕获媒体时保留网页播放', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requests = <Map>[];
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/source_web'),
      (call) async {
        if (call.method != 'render') return null;
        final args = call.arguments as Map;
        requests.add(args);
        return {
          'url': args['url'],
          'html': '<html></html>',
          'result': [],
          'media': [],
        };
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('lumebox/source_web'),
        null,
      ),
    );
    final engine = await openEngine(
      sourceId: 'kazumi-fixture',
      script: SourcePackage.prepare(jsonEncode(rule)),
    );
    addTearDown(engine.dispose);
    final list = await engine.call('list', {
      'keyword': '中文 & query',
      'page': 1,
    });
    expect((list as Map)['items'], isEmpty);
    expect(requests.first['method'], 'POST');
    expect(requests.first['url'], 'https://example.test/search');
    expect(requests.first['body'], 'q=${Uri.encodeComponent('中文 & query')}');
    expect(
      (requests.first['headers'] as Map)['Referer'],
      'https://example.test/',
    );
    final content = await engine.call('content', {
      'id': 'https://example.test/title',
      'chapterId': 'https://example.test/play',
    });
    expect((content as Map)['kind'], 'webplayer');
    expect(content['pageUrl'], 'https://example.test/play');
  }, skip: available ? false : '本机没有 QuickJS 原生桥');
}
