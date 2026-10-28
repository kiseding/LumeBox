import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_extension_settings.dart';
import 'package:lume_box/features/source/source_action_dialogs.dart';

void main() {
  testWidgets('多镜像、独立 CDN、自定义优先、专用设置和操作完整保存，取消不提交', (tester) async {
    SourceSettingsResult? saved;
    Map<String, Object?>? preview;
    final definitions = SourceSetting.parseAll([
      {'key': 'autoNext', 'type': 'toggle', 'title': '自动翻页'},
      {'key': 'limit', 'type': 'number', 'title': '每页数量', 'default': 20},
      {'key': 'refresh', 'type': 'action', 'title': '刷新分类', 'action': 'source'},
    ]);
    final config = SourceSiteConfig(
      mirrors: List.generate(5, (i) => 'https://m$i.example'),
      domainOverride: 'https://custom.example',
      images: SourceRoute.parse(['https://i1.example', 'https://i2.example']),
      video: SourceRoute.parse(['https://v1.example', 'https://v2.example']),
      settingDefinitions: definitions,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await showDialog<SourceSettingsResult>(
                  context: context,
                  builder: (_) => SourceNetworkDialog(
                    source: SourceDescriptor(
                      id: 'test',
                      name: '测试源',
                      version: '1',
                      enabled: true,
                      section: Section.video,
                      siteConfig: config,
                    ),
                    onSettingAction: (field, values, site) async {
                      preview = {...values, 'domain': site.resolvedDomain};
                      return '分类已刷新';
                    },
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tap(find.text('更多镜像（2）'));
    await tap(find.text('m4.example'));
    expect(find.text('当前生效：https://custom.example'), findsOneWidget);
    await tap(find.widgetWithText(DropdownButtonFormField<String>, '图床线路'));
    await tester.tap(find.text('https://i2.example').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(TextFormField, '自定义视频 CDN地址（填了优先）'),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '自定义视频 CDN地址（填了优先）'),
      'https://custom-v.example',
    );
    await tap(find.text('自动翻页'));
    await tester.enterText(find.widgetWithText(TextFormField, '每页数量'), '30');
    await tap(find.text('刷新分类'));
    expect(preview?['autoNext'], true);
    expect(preview?['limit'], 30);
    expect(preview?['domain'], 'https://custom.example');
    expect(saved, isNull, reason: '执行预览操作不自动提交整个设置');
    await tap(find.widgetWithText(FilledButton, '保存'));
    expect(saved?.site.selectedMirror, 'https://m4.example');
    expect(saved?.site.resolvedDomain, 'https://custom.example');
    expect(saved?.site.images.resolved, 'https://i2.example');
    expect(saved?.site.video.resolved, 'https://custom-v.example');
    expect(saved?.site.resolvedSettings, {'autoNext': true, 'limit': 30});
    saved = null;
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tap(find.widgetWithText(TextButton, '取消'));
    expect(saved, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('无效 CDN 与数字不保存，保留输入供修正', (tester) async {
    SourceSettingsResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<SourceSettingsResult>(
                  context: context,
                  builder: (_) => SourceNetworkDialog(
                    source: SourceDescriptor(
                      id: 'x',
                      name: 'X',
                      version: '1',
                      enabled: true,
                      siteConfig: SourceSiteConfig(
                        settingDefinitions: SourceSetting.parseAll([
                          {'key': 'n', 'type': 'number', 'title': '数量'},
                        ]),
                      ),
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final image = find.widgetWithText(TextFormField, '自定义图床地址（填了优先）');
    await tester.ensureVisible(image);
    await tester.enterText(image, 'javascript:bad');
    final number = find.widgetWithText(TextFormField, '数量');
    await tester.ensureVisible(number);
    await tester.enterText(number, 'oops');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('请填写有效的 HTTP(S) 图床地址'), findsOneWidget);
    expect(find.text('数量：请输入有效数字'), findsOneWidget);
  });
}
