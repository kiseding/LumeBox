import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/reading/comic_image_tools.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/features/comic/comic_image_tools_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 40, 80),
      Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(40, 80);
    bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });
  const region = {'text': 'こんにちは', 'x': .2, 'y': .3, 'width': .4, 'height': .1};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      switch (call.method) {
        case 'recognize':
          return [region];
        case 'translate':
          return ['你好'];
        case 'getKey':
          return 'test-secret';
        case 'superResolve':
          return bytes;
        default:
          return null;
      }
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(ComicImageTools.channel, null),
  );

  test('recognize sorts OCR regions for single-speaker reading', () async {
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method != 'recognize') {
        throw StateError('unexpected ${call.method}');
      }
      return [
        {'text': '底部', 'x': .1, 'y': .8, 'width': .5, 'height': .1},
        {'text': '右上', 'x': .6, 'y': .1, 'width': .2, 'height': .1},
        {'text': '左上', 'x': .1, 'y': .1, 'width': .2, 'height': .1},
        {'text': '  ', 'x': .3, 'y': .5, 'width': .1, 'height': .1},
      ];
    });
    final tools = ComicImageTools();
    expect(await tools.recognize(bytes), ['左上', '右上', '底部']);
    tools.dispose();
  });

  test('长图相邻行按实际文字高度排序，不把相隔面板误判为同一行', () async {
    messenger.setMockMethodCallHandler(
      ComicImageTools.channel,
      (call) async => [
        {'text': '下面一行', 'x': .1, 'y': .112, 'width': .3, 'height': .002},
        {'text': '上面一行', 'x': .8, 'y': .1, 'width': .1, 'height': .002},
      ],
    );
    final tools = ComicImageTools();
    expect(await tools.recognize(bytes), ['上面一行', '下面一行']);
    tools.dispose();
  });

  test('长图多于 250 个文字区域分批翻译，保留文字与全图坐标对应', () async {
    final batches = <List<String>>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'recognize') {
        return [
          for (var i = 0; i < 251; i++)
            {
              'text': 'line-$i',
              'x': .1,
              'y': i / 300,
              'width': .5,
              'height': .001,
            },
        ];
      }
      if (call.method == 'translate') {
        final texts = List<String>.from((call.arguments as Map)['texts']);
        batches.add(texts);
        return texts.map((value) => '译$value').toList();
      }
      return null;
    });
    final tools = ComicImageTools();
    final output = await tools.translate(bytes);
    expect(batches.map((batch) => batch.length), [100, 100, 51]);
    expect(output, hasLength(251));
    expect(output.last.text, 'line-250');
    expect(output.last.translation, '译line-250');
    expect(output.last.y, closeTo(250 / 300, .00001));
    tools.dispose();
  });

  test('翻译分批同时限制文字长度，单区域超限有明确错误', () async {
    var oversized = false;
    final batches = <List<String>>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'recognize') {
        return [
          for (var i = 0; i < (oversized ? 1 : 2); i++)
            {
              'text': '字' * (oversized ? 40001 : 25000),
              'x': .1,
              'y': i * .2,
              'width': .5,
              'height': .1,
            },
        ];
      }
      if (call.method == 'translate') {
        final texts = List<String>.from((call.arguments as Map)['texts']);
        batches.add(texts);
        return texts.map((value) => '译文').toList();
      }
      return null;
    });
    final tools = ComicImageTools();
    expect(await tools.translate(bytes), hasLength(2));
    expect(batches.map((batch) => batch.length), [1, 1]);
    oversized = true;
    await expectLater(tools.translate(bytes), throwsFormatException);
    expect(batches, hasLength(2));
    tools.dispose();
  });

  test(
    'model picker supplies an iOS UTI as well as desktop extension filters',
    () {
      final type = ComicImageToolsSettingsPage.modelFileTypes.single;
      expect(type.extensions, contains('mlmodel'));
      expect(type.uniformTypeIdentifiers, contains('public.data'));
    },
  );
  testWidgets(
    'model picker failure is visible and the import button can retry',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ComicImageToolsSettingsPage(
            pickModelFile: () async {
              attempts++;
              throw PlatformException(code: 'picker_failed');
            },
          ),
        ),
      );
      final button = find.byKey(const Key('import-super-resolution-model'));
      await tester.scrollUntilVisible(button, 250);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('无法打开文件选择器或安装模型，请重试'), findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cancelling model selection clears the busy state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ComicImageToolsSettingsPage(pickModelFile: () async => null),
      ),
    );
    final button = find.byKey(const Key('import-super-resolution-model'));
    await tester.scrollUntilVisible(button, 250);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('已取消选择模型'), findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
  test(
    'AI photo and manga model types reach the native backend independently',
    () async {
      final calls = <Map>[];
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
        if (call.method == 'superResolve') {
          calls.add(call.arguments as Map);
          return bytes;
        }
        return null;
      });
      final settings = ComicImageToolsSettings()
        ..imageStyle = 'photo'
        ..noise = 2;
      final tools = ComicImageTools(settings: settings);
      await tools.superResolve(bytes);
      settings.imageStyle = 'anime';
      await tools.superResolve(bytes);
      expect(calls.map((args) => args['imageStyle']), ['photo', 'anime']);
      expect(calls.map((args) => args['noise']), [2, 2]);
      tools.imageStyle = 'photo';
      await tools.superResolve(bytes);
      expect(calls.last['imageStyle'], 'photo', reason: '美图源选择覆盖全局漫画默认值');
      expect(settings.imageStyle, 'anime', reason: '源内模型选择不改全局设置');
      tools.dispose();
    },
  );

  test('model files match pinned provenance and license', () {
    final origin = jsonDecode(
      File('assets/models/waifu2x/ORIGIN.json').readAsStringSync(),
    ) as Map;
    for (final entry in (origin['sha256'] as Map).entries) {
      expect(
        sha256
            .convert(
              File('assets/models/waifu2x/${entry.key}').readAsBytesSync(),
            )
            .toString(),
        entry.value,
      );
    }
    expect(
      File('assets/models/waifu2x/LICENSE').readAsStringSync(),
      contains('Permission is hereby granted'),
    );
  });

  test(
    'device translation preserves OCR positions and original text',
    () async {
      final tools = ComicImageTools(settings: ComicImageToolsSettings());
      addTearDown(tools.dispose);
      final result = await tools.translate(bytes);
      expect(result.single.text, 'こんにちは');
      expect(result.single.translation, '你好');
      expect(result.single.x, .2);
      expect(result.single.y, .3);
      expect(result.single.height, .1);
    },
  );

  test(
    'AI sends text only, honors language and validates ordered JSON results',
    () async {
      final settings = ComicImageToolsSettings()
        ..ai = true
        ..endpoint = 'https://translation.example/v1/chat/completions'
        ..model = 'my-model';
      final client = MockClient((request) async {
        expect(request.followRedirects, false);
        expect(request.headers['Authorization'], 'Bearer test-secret');
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], 'my-model');
        expect(
          jsonDecode(
            ((body['messages'] as List).last as Map)['content'] as String,
          ),
          ['こんにちは'],
        );
        expect(request.body, isNot(contains('image_url')));
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '["你好"]'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(client.close);
      final tools = ComicImageTools(settings: settings, client: client);
      addTearDown(tools.dispose);
      expect((await tools.translate(bytes)).single.translation, '你好');
    },
  );

  test('malformed AI response cannot overwrite translation', () async {
    final settings = ComicImageToolsSettings()
      ..ai = true
      ..endpoint = 'https://translation.example/v1/chat/completions'
      ..model = 'my-model';
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '[]'},
            },
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);
    final tools = ComicImageTools(settings: settings, client: client);
    addTearDown(tools.dispose);
    await expectLater(tools.translate(bytes), throwsFormatException);
    for (final url in [
      'http://bad.example',
      'https://user:secret@example.com',
      'file:///tmp/model',
    ]) {
      expect(
        () => ComicImageTools.validateEndpoint(url),
        throwsFormatException,
      );
    }
  });

  test('all eight waifu2x models are bundled with the app', () async {
    for (final name in ComicImageTools.bundledModelNames) {
      final data = await rootBundle.load('assets/models/waifu2x/$name.mlmodel');
      expect(
        data.lengthInBytes,
        greaterThan(1 * 1024 * 1024),
        reason: '$name 应随 App 打包',
      );
    }
  });

  test(
    'installBundledModels installs all eight models via native channel',
    () async {
      final installed = <String>[];
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
        if (call.method == 'importModel') {
          installed.add((call.arguments as Map)['name'] as String);
        }
        return null;
      });
      final tools = ComicImageTools();
      await tools.installBundledModels();
      tools.dispose();
      expect(installed, <String>[
        'noise0.mlmodel',
        'noise1.mlmodel',
        'noise2.mlmodel',
        'noise3.mlmodel',
        'photo0.mlmodel',
        'photo1.mlmodel',
        'photo2.mlmodel',
        'photo3.mlmodel',
      ]);
    },
  );

  test('automatic upscale ranges are gated by the master switch', () {
    final settings = ComicImageToolsSettings();
    final tools = ComicImageTools(settings: settings);
    expect(tools.surfaceEnabled(UpscaleSurface.reader), isFalse);
    settings.automatic = true;
    expect(tools.surfaceEnabled(UpscaleSurface.reader), isTrue);
    expect(tools.surfaceEnabled(UpscaleSurface.cover), isFalse);
    expect(tools.surfaceEnabled(UpscaleSurface.videoPoster), isFalse);
    expect(tools.surfaceEnabled(UpscaleSurface.novelIllustration), isFalse);
    settings.upscaleCovers = true;
    settings.upscaleVideoPosters = true;
    settings.upscaleNovelIllustrations = true;
    expect(tools.surfaceEnabled(UpscaleSurface.cover), isTrue);
    expect(tools.surfaceEnabled(UpscaleSurface.videoPoster), isTrue);
    expect(tools.surfaceEnabled(UpscaleSurface.novelIllustration), isTrue);
    tools.dispose();
  });

  test(
    'new auto ranges and colorize config persist; concurrency clamps',
    () async {
      final dir = Directory.systemTemp.createTempSync('comic-image-settings');
      addTearDown(() => dir.deleteSync(recursive: true));
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async =>
            call.method == 'getApplicationSupportDirectory' ? dir.path : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        ),
      );
      final settings = ComicImageToolsSettings()
        ..automatic = true
        ..upscaleCovers = true
        ..upscaleVideoPosters = true
        ..upscaleNovelIllustrations = true
        ..concurrency = 9
        ..colorizeEndpoint = 'https://image.example/v1/images/edits'
        ..colorizeModel = 'image-model'
        ..colorizePrompt = 'colorize';
      await settings.save();
      final reloaded = ComicImageToolsSettings();
      await reloaded.boot();
      expect(reloaded.automatic, isTrue);
      expect(reloaded.upscaleCovers, isTrue);
      expect(reloaded.upscaleVideoPosters, isTrue);
      expect(reloaded.upscaleNovelIllustrations, isTrue);
      expect(reloaded.concurrency, 4);
      expect(
        reloaded.colorizeEndpoint,
        'https://image.example/v1/images/edits',
      );
      expect(reloaded.colorizeModel, 'image-model');
      expect(reloaded.colorizePrompt, 'colorize');
    },
  );

  test('cloud colorize uploads multipart and accepts b64_json only', () async {
    final settings = ComicImageToolsSettings()
      ..colorizeEndpoint = 'https://image.example/v1/images/edits'
      ..colorizeModel = 'image-model';
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer test-secret');
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="model"'));
      expect(body, contains('image-model'));
      expect(body, contains('name="image"'));
      expect(body, contains('response_format'));
      return http.Response(
        jsonEncode({
          'data': [
            {'b64_json': base64Encode(bytes)},
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final tools = ComicImageTools(settings: settings, client: client);
    addTearDown(tools.dispose);
    expect(await tools.colorize(bytes), bytes);

    final bad = ComicImageTools(
      settings: settings,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {'url': 'https://image.example/result.png'},
            ],
          }),
          200,
        ),
      ),
    );
    addTearDown(bad.dispose);
    await expectLater(bad.colorize(bytes), throwsFormatException);
  });

  test('closing reader cancels native jobs and rejects stale result', () async {
    final response = Completer<Object?>();
    final started = Completer<void>();
    final cancelled = <String>[];
    messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
      if (call.method == 'superResolve') {
        started.complete();
        return response.future;
      }
      if (call.method == 'cancel') {
        cancelled.add((call.arguments as Map)['id'] as String);
      }
      return null;
    });
    final tools = ComicImageTools();
    final future = tools.superResolve(bytes);
    final expectation = expectLater(future, throwsStateError);
    await started.future;
    tools.dispose();
    response.complete(bytes);
    await expectation;
    expect(cancelled, hasLength(1));
  });

  test(
    'automatic off returns exact original bytes without native calls',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (_) async {
        calls++;
        return null;
      });
      final tools = ComicImageTools(settings: ComicImageToolsSettings());
      expect(identical(await tools.automatic(bytes), bytes), true);
      expect(calls, 0);
      tools.dispose();
    },
  );

  test('decode enhancement leaves exported bytes unchanged', () async {
    final dir = Directory.systemTemp.createTempSync('comic-enhancement');
    var enhanced = 0;
    final pipeline = SectionImagePipeline(
      cacheDir: dir.path,
      diskCache: false,
      decodeTransform: (original) async {
        enhanced++;
        expect(original, bytes);
        return original;
      },
      requestSender: (_) async => NetworkResponse(
        statusCode: 200,
        body: bytes,
        headers: const {'content-type': 'image/png'},
      ),
    );
    addTearDown(() {
      pipeline.dispose();
      dir.deleteSync(recursive: true);
    });
    final image = await pipeline.image('https://images.example/page.png');
    expect(image, isNotNull);
    expect(enhanced, 1);
    expect(await pipeline.bytes('https://images.example/page.png'), bytes);
    expect(enhanced, 1);
    pipeline.release('https://images.example/page.png');

    // 按源隔离的子管线必须继承解码增强，否则自动超分在部分封面上会静默失效。
    final sub = pipeline.forSource(
      Section.comic,
      'source',
      NetworkProfile.none,
    );
    expect(sub.decodeTransform, isNotNull);
    sub.dispose();
  });

  testWidgets('apply-to-page returns enhanced bytes when allowApply', (
    tester,
  ) async {
    Uint8List? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              applied = await Navigator.of(context).push<Uint8List>(
                MaterialPageRoute<Uint8List>(
                  builder: (_) => ComicImageToolsPage(
                    allowApply: true,
                    loadOriginal: () async => bytes,
                  ),
                ),
              );
            },
            child: const Text('open tools'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open tools'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 超分当前图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用到当前页'));
    await tester.pumpAndSettle();
    expect(applied, bytes);
  });

  testWidgets('SR settings fit 320pt and expose the new sections', (
    tester,
  ) async {
    // 320pt 宽 + 拉高视口：一次建完整个设置页，直接检查排版与所有新区块。
    tester.view.physicalSize = const Size(320, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const ComicImageToolsSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in <String>[
      '自动超分的额外范围',
      '漫画 / 猫源封面',
      '视频海报',
      '小说封面 / 插图',
      '安装内置模型（8 个）',
      'AI 上色（实验性 · 云端）',
      '保存上色配置',
    ]) {
      expect(find.text(text), findsOneWidget, reason: '缺少「$text」');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'current page can translate, compare original and display failures',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ComicImageToolsPage(loadOriginal: () async => bytes)),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('翻译当前页'));
      await tester.pumpAndSettle();
      expect(find.text('你好'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('你好'), findsNothing);
      messenger.setMockMethodCallHandler(ComicImageTools.channel, (call) async {
        if (call.method == 'superResolve') {
          throw PlatformException(code: 'memory', message: '图片过大，原图保留');
        }
        return null;
      });
      await tester.tap(find.text('AI 超分当前图片'));
      await tester.pumpAndSettle();
      expect(find.text('图片过大，原图保留'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    },
  );
}
