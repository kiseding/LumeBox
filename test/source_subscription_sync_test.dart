import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/source/source_section_page.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_subscription_sync.dart';
import 'package:lume_box/core/net/source_subscription.dart';
import 'package:lume_box/core/net/network_settings.dart';

import 'support/fake_source_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Manager manager;
  late SourceSubscriptionSync service;
  late Map<String, String> remote;
  var now = DateTime(2026, 10, 13);
  const manifest = 'https://repo.example/sources.txt';
  setUp(() async {
    root = Directory.systemTemp.createTempSync('subscription-sync');
    manager = _Manager();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    remote = {};
    service = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: File('${root.path}/subscriptions.json'),
      clock: () => now,
      fetch: (url) async {
        final text = remote[url];
        if (text == null) throw StateError('HTTP 503');
        return SourceFetchResult(
          bytes: Uint8List.fromList(utf8.encode(text)),
          text: text,
        );
      },
    );
    await service.register([manifest]);
  });
  tearDown(() async {
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  String script(String id, int version) =>
      'var LumeSource = {id:"$id", name:"$id", version:"$version"};';

  test('地址与清单成员落盘；自动新增更新移除，保留手动源和停用状态', () async {
    remote[manifest] = 'https://repo.example/a.js\nhttps://repo.example/b.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    remote['https://repo.example/b.js'] = script('b', 1);
    expect((await service.sync()).added, 2);
    await manager.setEnabled('a', false);
    manager.sources.add(
      const SourceDescriptor(
        id: 'local',
        name: '手动',
        version: '1',
        enabled: true,
      ),
    );
    final restarted = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: service.file,
      fetch: service.fetch,
    );
    await restarted.load();
    expect(restarted.subscriptions.single.url, manifest);
    expect(
      restarted.subscriptions.single.members.keys,
      containsAll(['a', 'b']),
    );
    remote[manifest] = 'https://repo.example/a.js\nhttps://repo.example/c.js';
    remote['https://repo.example/a.js'] = script('a', 2);
    remote['https://repo.example/c.js'] = script('c', 1);
    final result = await restarted.sync(force: true);
    expect(result.updated, 1);
    expect(result.added, 1);
    expect(result.removed, 1);
    expect(manager.sources.map((s) => s.id), containsAll(['a', 'c', 'local']));
    expect(manager.sources.firstWhere((s) => s.id == 'a').enabled, false);
  });
  test('拉取部分失败不把暂时取不到的源误删；健康检查六小时内去重', () async {
    remote[manifest] = 'https://repo.example/a.js\nhttps://repo.example/b.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    remote['https://repo.example/b.js'] = script('b', 1);
    await service.sync();
    remote.remove('https://repo.example/b.js');
    expect((await service.sync()).errors, isEmpty, reason: '未到检查时间');
    final result = await service.sync(force: true);
    expect(result.errors, isNotEmpty);
    expect(manager.removed, isEmpty);
    expect(manager.sources.map((s) => s.id), contains('b'));
  });
  test('HTML错误页不执行移除；可信空清单仅移除该订阅成员', () async {
    remote[manifest] = 'https://repo.example/a.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    await service.sync();
    remote[manifest] = '<html>Access denied</html>';
    expect((await service.sync(force: true)).errors, isNotEmpty);
    expect(manager.removed, isEmpty);
    remote[manifest] = '# 该订阅已清空\n';
    expect((await service.sync(force: true)).removed, 1);
    expect(manager.removed, ['a']);
  });
  test('取消订阅持久化，重启后不重新拉取或清除手动源', () async {
    service.subscriptions.clear();
    await service.save();
    final restarted = SourceSubscriptionSync(
      section: Section.video,
      manager: manager,
      file: service.file,
      fetch: (_) async => throw StateError('不应请求'),
    );
    await restarted.load();
    expect((await restarted.sync(force: true)).errors, isEmpty);
    expect(restarted.subscriptions, isEmpty);
  });
  test('禁用订阅不会拉取，手动导入同ID保护由专门导入端口保证', () async {
    service.subscriptions.single.enabled = false;
    expect((await service.sync(force: true)).errors, isEmpty);
    expect(manager.imported, isEmpty);
  });
  testWidgets('常驻订阅入口：添加一次、返回重进保留链接、无需粘贴即可更新', (tester) async {
    await tester.runAsync(
      () => SourceSubscriptionSync.open(Section.video, manager: manager),
    );
    remote[manifest] = 'https://repo.example/a.js';
    remote['https://repo.example/a.js'] = script('a', 1);
    await tester.binding.setSurfaceSize(const Size(440, 956));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: SourceSectionPage(
          section: Section.video,
          manager: manager,
          fetchSubscription: service.fetch,
        ),
      ),
    );
    await settle();
    expect(find.text('订阅管理 · 添加订阅链接'), findsOneWidget);
    await tester.tap(find.text('订阅管理 · 添加订阅链接'));
    await settle();
    await tester.enterText(find.byType(TextField), manifest);
    await tester.tap(find.text('添加订阅并导入'));
    await settle();
    expect(manager.sources.single.version, '1');
    expect(find.text(manifest), findsOneWidget);
    await tester.pageBack();
    await settle();
    expect(find.textContaining('已保存 1 个订阅'), findsOneWidget);
    await tester.tap(find.text('订阅管理 · 添加订阅链接'));
    await settle();
    expect(find.text(manifest), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    remote['https://repo.example/a.js'] = script('a', 2);
    await tester.tap(find.text('更新已保存的订阅'));
    await settle();
    expect(manager.sources.single.version, '2');
  });
}

class _Manager extends FakeSourceManager implements SubscriptionImportManager {
  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {
    final old = sources.firstWhere((s) => s.id == sourceId);
    sources.remove(old);
    sources.add(
      SourceDescriptor(
        id: old.id,
        name: old.name,
        version: old.version,
        enabled: enabled,
        originUrl: old.originUrl,
        network: old.network,
      ),
    );
  }

  @override
  Future<SourceImportResult> importSubscription(
    String script, {
    required String originUrl,
  }) async {
    final id = RegExp('id:"([^"]+)"').firstMatch(script)!.group(1)!;
    final version = RegExp('version:"([^"]+)"').firstMatch(script)!.group(1)!;
    final old = sources.where((s) => s.id == id).firstOrNull;
    if (old != null && old.originUrl.isEmpty) {
      return const SourceImportResult.failure('保留手动源');
    }
    sources.removeWhere((s) => s.id == id);
    final next = SourceDescriptor(
      id: id,
      name: id,
      version: version,
      enabled: old?.enabled ?? true,
      originUrl: originUrl,
      network: old?.network ?? const NetworkProfile(),
    );
    sources.add(next);
    scripts[id] = script;
    imported.add(script);
    return SourceImportResult.success(next);
  }
}
