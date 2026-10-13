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
            mergeHomeHeader: true,
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
    expect(find.byType(AppBar), findsNothing, reason: '标题与功能合到一个悬浮模块');
    expect(find.byTooltip('筛选'), findsNothing);
    expect(find.text('筛选'), findsNothing);
    expect(find.text('打开筛选'), findsNothing);
    expect(
      tester.getCenter(find.text('源A')).dy,
      lessThan(tester.getCenter(find.text('网站大分类')).dy),
    );
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
    await tester.drag(find.byType(GridView), const Offset(0, -360));
    await tester.pumpAndSettle();
    final opacity = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .map((w) => w.opacity);
    expect(opacity, contains(0), reason: '上滑收起整块顶部导航、分类与筛选');
    await tester.drag(find.byType(GridView), const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .map((w) => w.opacity),
      everyElement(1),
    );
  });

  testWidgets('五组网站筛选全部直接显示，第五行可选择并下发', (tester) async {
    final source = _ManyFilterSource();
    await show(
      tester,
      FakeSourceManager(
        sources: const [
          SourceDescriptor(id: 'a', name: '源A', version: '1', enabled: true),
        ],
        opened: {'a': source},
      ),
    );
    for (var i = 1; i <= 5; i++) {
      expect(find.text('网站第$i行'), findsOneWidget);
    }
    expect(find.text('展开全部筛选'), findsNothing);
    await tester.tap(find.text('第五组条件5'));
    await tester.pumpAndSettle();
    expect(source.requests.last.$2, {'row5': 'pick5'});
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('分类指定类型时，筛选类型的高亮和实际请求一致', (tester) async {
    final source = _TypedFilterSource();
    await show(
      tester,
      FakeSourceManager(
        sources: const [
          SourceDescriptor(id: 'a', name: '源A', version: '1', enabled: true),
        ],
        opened: {'a': source},
      ),
    );
    await tester.tap(find.text('电影分类'));
    await tester.pumpAndSettle();
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '电影类型'),
    );
    expect(
      button.style!.backgroundColor!.resolve({}),
      LumeTheme.accent.withValues(alpha: .15),
    );
    expect(source.requests.last.$1, '1');
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
            mergeHomeHeader: true,
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

class _ManyFilterSource extends _FilterSource {
  _ManyFilterSource() : super('a', '网站分类', '网站分组', '网站条件');
  @override
  Future<List<SourceFilterGroup>> filters() async => [
    for (var i = 1; i <= 5; i++)
      SourceFilterGroup(
        id: 'row$i',
        title: '网站第$i行',
        options: [SourceFilterOption(id: 'pick$i', title: '第五组条件$i')],
      ),
  ];
}

class _TypedFilterSource extends _FilterSource {
  _TypedFilterSource() : super('a', '电影分类', '类型', '电影类型');
  @override
  Future<List<SourceCategory>> categories() async => const [
    SourceCategory(id: '1', title: '电影分类'),
  ];
  @override
  Future<List<SourceFilterGroup>> filters() async => const [
    SourceFilterGroup(
      id: 'tid',
      title: '类型',
      options: [
        SourceFilterOption(id: '0', title: '全部'),
        SourceFilterOption(id: '1', title: '电影类型'),
      ],
    ),
  ];
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
