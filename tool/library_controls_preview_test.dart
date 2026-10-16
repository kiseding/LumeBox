import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/novel/novel_page.dart';
import 'package:lume_box/features/video/video_page.dart';
import 'package:lume_box/features/reading/history_sheet.dart';
import 'package:lume_box/features/source/source_section_page.dart';

import '../test/support/fake_source_manager.dart';

// Local visual check: flutter test tool/library_controls_preview_test.dart.
// Renders the real controls at both compact phone widths, without network data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUpAll(() async {
    for (final entry in {
      'Preview': 'C:/Windows/Fonts/Deng.ttf',
      'MaterialIcons': 'C:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then((b) => b.buffer.asByteData()),
      );
      await loader.load();
    }
    root = Directory.systemTemp.createTempSync('lumebox-controls-preview-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    for (final section in Section.values) {
      await SectionScope.open(section);
      await ReadingLibrary.open(section);
    }
    await CatService.instance.boot();
    Directory('build/library_controls_preview').createSync(recursive: true);
  });
  tearDownAll(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  testWidgets('four board and history controls fit narrow phones', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final base = LumeTheme.build();
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Preview'),
    );
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'demo',
          name: '演示视频源',
          version: '1',
          enabled: true,
          group: '常用视频源',
        ),
        SourceDescriptor(
          id: 'adult',
          name: '18+ 成人站点示例',
          version: '1',
          enabled: true,
          group: '独立分组',
        ),
      ],
    );
    for (final width in [320.0, 390.0]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.runAsync(() async {
        for (final section in Section.values) {
          await ReadingLibrary.open(section);
        }
      });
      final library = ReadingLibrary.find(Section.video)!;
      library.setSetting(
        'favorites.lastCheck',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      for (var n = 0; n < 4; n++) {
        library.shelve(sourceId: 'demo', itemId: '$n', title: '演示影片第${n + 1}部');
        library.saveProgress(
          VideoProgress(
            section: Section.video,
            itemId: '$n',
            chapterId: 'ep',
            chapterTitle: '第1集',
            chapterIndex: 0,
            updatedAt: DateTime.now(),
            position: const Duration(minutes: 12),
            duration: const Duration(minutes: 45),
          ),
        );
      }
      final pages = <String, Widget>{
        'novel': NovelPage(runtimeAvailable: true, manager: manager),
        'comic': ComicPage(runtimeAvailable: true, manager: manager),
        'video': VideoPage(sourceManager: manager, library: library),
        'cat': const CatPage(),
        'sources': SourceSectionPage(section: Section.video, manager: manager),
        'history': Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ReadingHistorySheet(
              section: Section.video,
              library: ReadingLibrary.find(Section.video)!,
              onResume: (_, _) {},
            ),
          ),
        ),
        'favorites': Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ReadingHistorySheet(
              section: Section.video,
              library: library,
              initialTab: HistoryDrawerTab.favorites,
              onResume: (_, _) {},
            ),
          ),
        ),
      };
      for (final entry in pages.entries) {
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              home: entry.value,
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key} at $width',
        );
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/library_controls_preview/${entry.key}-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      }
    }
  });
}
