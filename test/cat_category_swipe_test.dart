import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/cat/cat_page.dart';
import 'package:lume_box/shared/widgets/browse_category_swipe.dart';

const site = CatSite(
  subscriptionId: 'swipe-pack',
  key: 'swipe-site',
  name: '分类测试站',
  api: '/fixture',
);

class _Cats extends CatService {
  _Cats() : super.testing();
  final requests = <String>[];
  Completer<void>? categoryGate;
  @override
  Future<void> boot() async {}
  @override
  Future<void> checkUpdates() async {}
  @override
  Future<void> select(CatSite site) async {
    selectedSiteId = site.id;
  }

  @override
  Future<Map<String, dynamic>> call(
    CatSite site,
    String operation, [
    Map<String, dynamic> body = const {},
  ]) async {
    final id = body['id']?.toString() ?? '';
    if (operation == 'category') {
      requests.add(id);
      await categoryGate?.future;
    }
    return {
      'class': [
        {'type_id': 'a', 'type_name': '电影'},
        {'type_id': 'b', 'type_name': '剧集'},
      ],
      'list': [
        for (var i = 0; i < 24; i++)
          {
            'vod_id': '$operation-$id-$i',
            'vod_name': operation == 'category' ? '分类$id作品$i' : '首页作品$i',
          },
      ],
      'page': 1,
      'pagecount': 1,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Cats service;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('cat-category-swipe-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await ReadingLibrary.open(Section.cat);
    service = _Cats();
  });
  tearDown(() async {
    service.dispose();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    root.deleteSync(recursive: true);
  });
  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(440, 956));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: CatPage(service: service, requestedSite: site),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }

  Future<void> swipe(WidgetTester tester, Offset delta) async {
    final box = tester.getRect(
      find.byKey(const ValueKey('cat-category-swipe')),
    );
    await tester.dragFrom(
      Offset(box.left + box.width * .55, box.top + box.height * .7),
      delta,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('猫源内容区左右滑加载真实分类，短滑和竖滑不切换，首尾不循环', (tester) async {
    await show(tester);
    expect(find.text('首页作品0'), findsOneWidget);
    await swipe(tester, const Offset(-150, 0));
    expect(service.requests.last, 'a');
    expect(find.text('分类a作品0'), findsOneWidget);
    await swipe(tester, const Offset(-150, 0));
    expect(service.requests.last, 'b');
    final count = service.requests.length;
    await swipe(tester, const Offset(-150, 0));
    await swipe(tester, const Offset(25, 0));
    await swipe(tester, const Offset(0, -150));
    expect(service.requests.length, count);
    await swipe(tester, const Offset(150, 0));
    expect(service.requests.last, 'a');
    await swipe(tester, const Offset(150, 0));
    expect(find.text('首页作品0'), findsOneWidget);
    final allCount = service.requests.length;
    await swipe(tester, const Offset(150, 0));
    expect(service.requests.length, allCount);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('分类装载期间不重复切换或跳过中间分类', (tester) async {
    await show(tester);
    service.categoryGate = Completer<void>();
    final box = tester.getRect(
      find.byKey(const ValueKey('cat-category-swipe')),
    );
    await tester.dragFrom(box.center, const Offset(-150, 0));
    await tester.pump();
    expect(service.requests, ['a']);
    await tester.dragFrom(box.center, const Offset(-150, 0));
    await tester.pump();
    expect(service.requests, ['a']);
    service.categoryGate!.complete();
    await tester.pumpAndSettle();
    await swipe(tester, const Offset(-150, 0));
    expect(service.requests, ['a', 'b']);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('共享分类手势不抢左右边缘，禁用后不切换', (tester) async {
    final steps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowseCategorySwipe(
            enabled: true,
            onStep: steps.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(BrowseCategorySwipe));
    await tester.dragFrom(
      Offset(box.left + 10, box.center.dy),
      const Offset(150, 0),
    );
    await tester.dragFrom(
      Offset(box.right - 10, box.center.dy),
      const Offset(-150, 0),
    );
    expect(steps, isEmpty);
    await tester.dragFrom(box.center, const Offset(-150, 0));
    expect(steps, [1]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowseCategorySwipe(
            enabled: false,
            onStep: steps.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.dragFrom(box.center, const Offset(150, 0));
    expect(steps, [1]);
  });
}
