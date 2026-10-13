import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('lume_inline_facets');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    await SectionScope.open(Section.video);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    directory.deleteSync(recursive: true);
  });

  Future<void> show(
    WidgetTester tester,
    FakeSourceManager manager, {
    int revision = 0,
  }) async {
    await tester.binding.setSurfaceSize(const Size(440, 956));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: ShellDockScope(
          controller: ShellDockController(),
          dockInset: 94,
          child: const _ScopePlaceholder(),
        ),
      ),
    );
    // Reuse the same source view across revision updates.
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: ShellDockScope(
          controller: ShellDockController(),
          dockInset: 94,
          child: GlassScaffold(
            title: '视频',
            behindBar: true,
            floatingBar: true,
            child: ExploreView(
              section: Section.video,
              manager: manager,
              revision: revision,
              onOpenItem: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('源分类在筛选上方，选择原始 id 下发；滚动视口铺到最底边', (tester) async {
    final source = _FilterSource('a', '网站大分类', '网站地区', '网站选项');
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(id: 'a', name: '源A', version: '1', enabled: true),
      ],
      opened: {'a': source},
    );
    await show(tester, manager);
    expect(find.byTooltip('筛选'), findsNothing);
    expect(
      tester.getCenter(find.text('网站大分类')).dy,
      lessThan(tester.getCenter(find.text('网站选项')).dy),
    );
    final rect = tester.getRect(find.byType(GridView));
    expect(rect.top, 0);
    expect(rect.bottom, 956, reason: 'Dock 脚印只在列表尾部避让，不裁掉视口');
    await tester.tap(find.text('网站大分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('网站选项'));
    await tester.pumpAndSettle();
    expect(source.requests.last.$1, 'category-a');
    expect(source.requests.last.$2, {'region-a': 'option-a'});
  });

  testWidgets('切源后旧源晚返回的分类和筛选不能覆盖新源', (tester) async {
    final old = _FilterSource('a', '旧分类', '旧筛选', '旧选项')
      ..pendingCategories = Completer<List<SourceCategory>>();
    final current = _FilterSource('b', '新分类', '新筛选', '新选项');
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(id: 'a', name: '源A', version: '1', enabled: true),
        SourceDescriptor(id: 'b', name: '源B', version: '1', enabled: true),
      ],
      opened: {'a': old, 'b': current},
    );
    await show(tester, manager);
    await manager.select('b');
    // Keep the mounted view, so the old async request really races the new one.
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: ShellDockScope(
          controller: ShellDockController(),
          dockInset: 94,
          child: GlassScaffold(
            title: '视频',
            behindBar: true,
            floatingBar: true,
            child: ExploreView(
              section: Section.video,
              manager: manager,
              revision: 1,
              onOpenItem: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    old.pendingCategories!.complete(const [
      SourceCategory(id: 'old', title: '过期分类'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('新分类'), findsOneWidget);
    expect(find.text('新筛选'), findsOneWidget);
    expect(find.text('过期分类'), findsNothing);
    expect(find.text('旧选项'), findsNothing);
  });
}

class _ScopePlaceholder extends StatelessWidget {
  const _ScopePlaceholder();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _FilterSource extends FakeReadingDataSource implements FilterCapable {
  _FilterSource(
    this.sourceId,
    this.categoryTitle,
    this.groupTitle,
    this.optionTitle,
  ) : super(section: Section.video);
  final String sourceId, categoryTitle, groupTitle, optionTitle;
  Completer<List<SourceCategory>>? pendingCategories;
  final requests = <(String?, Map<String, String>?)>[];
  @override
  String get id => sourceId;
  @override
  Future<List<SourceCategory>> categories() async => pendingCategories == null
      ? [SourceCategory(id: 'category-$sourceId', title: categoryTitle)]
      : await pendingCategories!.future;
  @override
  Future<bool> supportsFilters() async => true;
  @override
  Future<List<SourceFilterGroup>> filters() async => [
    SourceFilterGroup(
      id: 'region-$sourceId',
      title: groupTitle,
      options: [SourceFilterOption(id: 'option-$sourceId', title: optionTitle)],
    ),
  ];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    requests.add((categoryId, filters));
    return SourceList(
      items: [
        for (var i = 0; i < 30; i++) SourceItem(id: '$i', title: '源作品 $i'),
      ],
      hasMore: false,
    );
  }
}
