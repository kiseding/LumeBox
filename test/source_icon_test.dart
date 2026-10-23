import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/source/source_favicon.dart';
import 'package:lume_box/shared/widgets/source_icon.dart';

/// 源图标（真机反馈「源图标好多都没有」）：候选地址、首页解析、图片校验、缓存。
///
/// 这一份把「图标怎么被找出来」钉住——站点把 /favicon.ico 写成 404 页、
/// 换成 PNG、或只写在首页 `<link rel=icon>` 里，都要能走到真图标；
/// 全都拿不到时必须老实回退首字母，不许把 HTML 当图片画出来。
void main() {
  test('ICO 站点图标转换为 Flutter 可解码的 PNG', () async {
    final ico = img.encodeIco(img.Image(width: 16, height: 16));
    final resolver = SourceFavicon(
      http: LumeHttp(
        source: 'ICO',
        client: MockClient(
          (_) async => http.Response.bytes(
            ico,
            200,
            headers: {'content-type': 'image/x-icon'},
          ),
        ),
      ),
    );
    final bytes = await resolver.load(origin: 'https://ico.example');
    expect(bytes!.take(4), [0x89, 0x50, 0x4e, 0x47]);
    expect(img.decodePng(bytes)?.width, 16);
  });

  test('失败的图标不永久缓存，网络恢复后能再次获取', () async {
    var ready = false;
    final data = img.encodePng(img.Image(width: 2, height: 2));
    final resolver = SourceFavicon(
      http: LumeHttp(
        source: 'retry',
        client: MockClient(
          (_) async => http.Response.bytes(
            ready ? data : [],
            ready ? 200 : 403,
            headers: {'content-type': 'image/png'},
          ),
        ),
      ),
    );
    expect(await resolver.load(origin: 'https://retry.example'), isNull);
    ready = true;
    expect(await resolver.load(origin: 'https://retry.example'), isNotNull);
  });

  /// 1x1 PNG（最小可解码图片）：用来当「真图标」。
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAF/gH8YQ3G'
    'AAAAAElFTkSuQmCC',
  );

  test('首页解析：apple-touch-icon 优先、相对地址补全、SVG 直接跳过', () {
    final html = '''
<html><head>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="icon" sizes="32x32" href="/img/icon32.png">
<link rel="apple-touch-icon-precomposed" sizes="180x180" href="/img/logo256.png">
<link rel="shortcut icon" href="favicon.ico">
</head></html>''';
    final links = SourceFavicon.iconLinksFromHtml(html, 'https://a.com');
    // apple-touch-icon 排第一（浏览器也是这个优先级）；SVG 那条被丢掉。
    expect(links.first, 'https://a.com/img/logo256.png');
    expect(links.first, isNot(contains('.svg')));
    expect(links.toSet(), <String>{
      'https://a.com/img/logo256.png',
      'https://a.com/img/icon32.png',
      'https://a.com/favicon.ico',
    });
    // 站点没给图标时给空列表（调用方据此收手，不再瞎猜）。
    expect(
      SourceFavicon.iconLinksFromHtml('<html></html>', 'https://a.com'),
      isEmpty,
    );
  });

  test(
    '候选顺序：源声明的图标 → /favicon.ico → /favicon.png → apple-touch-icon',
    () async {
      final asked = <String>[];
      final resolver = SourceFavicon(
        http: LumeHttp(
          source: '测试',
          client: MockClient((request) async {
            asked.add(request.url.toString());
            return http.Response.bytes(<int>[], 404);
          }),
        ),
      );
      await resolver.load(
        origin: 'https://a.com',
        explicit: <String>['https://cdn.example.com/my.png'],
      );
      expect(asked, <String>[
        'https://cdn.example.com/my.png',
        'https://a.com/favicon.ico',
        'https://a.com/favicon.png',
        'https://a.com/apple-touch-icon.png',
        'https://a.com/',
      ]);
    },
  );

  test('favicon.ico 是 404 页：继续找首页 <link rel=icon> 里的真图标', () async {
    final asked = <String>[];
    final resolver = SourceFavicon(
      http: LumeHttp(
        source: '测试',
        client: MockClient((request) async {
          final url = request.url.toString();
          asked.add(url);
          if (url == 'https://a.com/') {
            return http.Response(
              '<html><head><link rel="icon" href="/img/logo256.png"></head></html>',
              200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8',
              },
            );
          }
          if (url == 'https://a.com/img/logo256.png') {
            return http.Response.bytes(
              png,
              200,
              headers: <String, String>{'content-type': 'image/png'},
            );
          }
          // /favicon.ico 回的是站点的 404 HTML 页（很多站都这样）。
          return http.Response(
            '<html><body>not found</body></html>',
            404,
            headers: <String, String>{'content-type': 'text/html'},
          );
        }),
      ),
    );
    final bytes = await resolver.load(origin: 'https://a.com');
    expect(bytes, isNotNull);
    expect(bytes!.length, png.length);
    expect(asked.last, 'https://a.com/img/logo256.png');
  });

  test('内容不是图片就当没有：HTML / SVG / 空响应都不算图标', () async {
    Future<Uint8List?> load(http.Response Function(http.Request) respond) {
      final resolver = SourceFavicon(
        http: LumeHttp(
          source: '测试',
          client: MockClient((r) async => respond(r)),
        ),
      );
      return resolver.load(origin: 'https://a.com');
    }

    // 状态码 200、content-type 说自己是 png，内容却是 HTML——不许当图片画。
    expect(
      await load(
        (_) => http.Response(
          '<html><body>nginx</body></html>',
          200,
          headers: <String, String>{'content-type': 'image/png'},
        ),
      ),
      isNull,
    );
    // SVG：Flutter 画不了，当作没有。
    expect(
      await load(
        (_) => http.Response(
          '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
          200,
          headers: <String, String>{'content-type': 'image/svg+xml'},
        ),
      ),
      isNull,
    );
    expect(
      await load(
        (_) => http.Response.bytes(
          <int>[],
          200,
          headers: <String, String>{'content-type': 'image/png'},
        ),
      ),
      isNull,
    );
  });

  test('同一个源只请求一次：结果（含失败）都进缓存', () async {
    var calls = 0;
    final resolver = SourceFavicon(
      http: LumeHttp(
        source: '测试',
        client: MockClient((request) async {
          calls++;
          return http.Response.bytes(
            png,
            200,
            headers: <String, String>{'content-type': 'image/png'},
          );
        }),
      ),
    );
    final first = await resolver.load(origin: 'https://a.com');
    final second = await resolver.load(origin: 'https://a.com');
    expect(first, isNotNull);
    expect(second, same(first));
    expect(calls, 1, reason: '列表滚动 / 切页签不该把同一个站重打一遍');

    // 并发调用也只发一次（在飞表去重）。
    resolver.clearCache();
    calls = 0;
    await Future.wait(<Future<Uint8List?>>[
      resolver.load(origin: 'https://a.com'),
      resolver.load(origin: 'https://a.com'),
    ]);
    expect(calls, 1);
  });

  testWidgets('控件：拿不到图标显示首字母，拿到就画图', (tester) async {
    SourceFavicon resolver(Uint8List? bytes) => SourceFavicon(
      http: LumeHttp(
        source: '测试',
        client: MockClient(
          (request) async => bytes == null
              ? http.Response.bytes(<int>[], 404)
              : http.Response.bytes(
                  bytes,
                  200,
                  headers: <String, String>{'content-type': 'image/png'},
                ),
        ),
      ),
      fetchHtmlHomepage: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            SourceIcon(
              name: '禁漫天堂',
              siteUrl: 'https://a.com',
              favicon: resolver(null),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('禁'), findsOneWidget, reason: '取不到时回退首字母');
    expect(find.byType(Image), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            SourceIcon(
              name: '禁漫天堂',
              siteUrl: 'https://a.com',
              favicon: resolver(png),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('禁'), findsNothing);
  });
}
