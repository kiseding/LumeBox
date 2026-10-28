import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_extension_settings.dart';
import 'package:lume_box/core/source/source_preferences.dart';
import 'package:lume_box/features/source/source_preferences_page.dart';

import 'support/fake_source_manager.dart';

void main() {
  testWidgets('首页直接编辑站点并一次保存，滚到页底后仍保留输入且没有重复入口', (tester) async {
    final root = Directory.systemTemp.createTempSync('compact-source-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    await tester.runAsync(() => ReadingLibrary.open(Section.video));
    addTearDown(() async {
      ReadingLibrary.disposeAll();
      ReadingStore.disposeAll();
      await SectionScope.closeAll();
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      root.deleteSync(recursive: true);
    });
    const source = SourceDescriptor(
      id: 'compact',
      name: '测试源',
      version: '1',
      enabled: true,
      section: Section.video,
      siteUrl: 'https://old.example',
      siteConfig: SourceSiteConfig(
        mirrors: ['https://old.example'],
        settingDefinitions: [
          SourceSetting(
            key: 'more',
            title: '额外开关',
            type: 'toggle',
            defaultValue: false,
          ),
        ],
      ),
    );
    final manager = FakeSourceManager(sources: [source]);
    await tester.pumpWidget(
      MaterialApp(
        home: SourcePreferencesPage(
          section: Section.video,
          sourceId: source.id,
          name: source.name,
          descriptor: source,
          siteUrl: source.siteUrl,
          manager: manager,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('源设置（站点 / 图床 / 视频 CDN / 参数）'), findsNothing);
    expect(find.text('打开当前站点'), findsNothing);
    expect(find.text('打开站点网页登录 / 检查状态'), findsNothing);
    final domain = find.widgetWithText(TextField, '自定义域名（填了优先）');
    await tester.ensureVisible(domain);
    await tester.enterText(domain, 'https://new.example');
    await tester.scrollUntilVisible(
      find.text('恢复默认源设置'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('清理此源的浏览缓存'), findsOneWidget);
    expect(find.text('清理源浏览缓存'), findsNothing);
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
    expect(manager.siteConfigs, hasLength(1));
    expect(manager.siteConfigs.single.$2.resolvedDomain, 'https://new.example');
    expect(manager.networks, hasLength(1));
    expect(
      SourcePreferences.read(Section.video, source.id).customOrigin,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
