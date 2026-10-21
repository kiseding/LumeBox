import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/danmaku/dandanplay_client.dart';
import 'package:lume_box/features/video/danmaku/danmaku_match_sheet.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';

void main() {
  for (final landscape in [false, true]) {
    testWidgets('匹配先核对作品和集数，空弹幕不提交，横屏=$landscape', (tester) async {
      await tester.binding.setSurfaceSize(
        landscape ? const Size(900, 450) : const Size(450, 850),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var empty = true;
      final requests = <Uri>[];
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          '',
          '',
          baseUrl: 'https://danmu.example/custom',
        ),
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(
              request.url.path.contains('/comment/')
                  ? {
                      'comments': empty
                          ? []
                          : [
                              {'p': '0,1,16777215,test', 'm': '第一集弹幕'},
                            ],
                    }
                  : {
                      'animes': [
                        {
                          'animeId': 1,
                          'animeTitle': '熔城(2026)【电视剧】from tencent',
                          'episodes': [
                            {'episodeId': 11, 'episodeTitle': '【qq】 熔城_01'},
                            {'episodeId': 12, 'episodeTitle': '第2集'},
                          ],
                        },
                        {
                          'animeId': 2,
                          'animeTitle': '活火熔城(1997)【电影】from 360',
                          'episodes': [
                            {'episodeId': 21, 'episodeTitle': '正片'},
                          ],
                        },
                      ],
                    },
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);
      DanmakuMatchSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    selected = await showDanmakuPanel<DanmakuMatchSelection>(
                      context: context,
                      builder: (_) => DanmakuMatchSheet(
                        client: client,
                        title: '熔城',
                        episode: 1,
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(requests.single.queryParameters['episode'], '1');
      // Both fields stay usable above the software keyboard in either layout.
      tester.view.viewInsets = FakeViewPadding(
        bottom: (landscape ? 300 : 300) * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      final field = tester.getRect(
        find.byKey(const ValueKey('danmaku-match-title')),
      );
      expect(field.height, greaterThan(36));
      expect(
        field.bottom,
        lessThan((landscape ? 450 : 850) - (landscape ? 300 : 300)),
      );
      await tester.enterText(
        find.byKey(const ValueKey('danmaku-match-title')),
        '熔城测试',
      );
      expect(find.text('熔城测试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('熔城'), findsWidgets);
      expect(find.text('活火熔城'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('danmaku-work-1|2026|tencent')),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前集数'), findsOneWidget);
      await tester.tap(find.text('加载所选集弹幕'));
      await tester.pumpAndSettle();
      expect(requests.last.path, '/custom/api/v2/comment/11');
      expect(selected, isNull);
      expect(find.byKey(const ValueKey('danmaku-match-error')), findsOneWidget);
      empty = false;
      await tester.tap(find.text('加载所选集弹幕'));
      await tester.pumpAndSettle();
      expect(selected?.episode.id, '11');
      expect(selected?.track.length, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
