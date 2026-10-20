import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  late Directory root;
  setUp(() async {
    enableEngineOnThisPlatform();
    root = Directory.systemTemp.createTempSync('lume_modules');
    await installTempSectionRoot(root);
  });
  tearDown(() async {
    SourceRegistry.close(Section.video);
    await SectionScope.closeAll();
    restoreEnginePlatformGate();
    root.deleteSync(recursive: true);
  });
  for (final style in ['default', 'named', 'commonjs']) {
    test('真实 QuickJS $style：导入、分类、搜索、详情、选集、播放与重开', () async {
      final manager = LumeSources.manager(Section.video);
      final declaration = style == 'named' ? 'export ' : '';
      final script =
          '''
// LumeSource: {"id":"module-$style","name":"模块 $style","category":"video"}
// LumeRuntime: module
${declaration}function categories() { return [{id:'movie',title:'电影'}]; }
${declaration}function list(a) { return {items:[{id:'1',title:a.keyword || '首页'}],hasMore:false}; }
${declaration}function detail(a) { return {id:a.id,title:'详情'}; }
${declaration}function chapters(a) { return [{id:'ep1',title:'第一集'}]; }
${declaration}function content(a) { return {kind:'video',url:'https://example.org/video.mp4',headers:{Referer:'https://example.org/'}}; }
${style == 'default'
              ? 'export default {categories,list,detail,chapters,content};'
              : style == 'commonjs'
              ? 'module.exports = {categories,list,detail,chapters,content};'
              : ''}
''';
      final imported = await manager.importScript(script);
      expect(imported.isSuccess, isTrue, reason: imported.message);
      expect(imported.descriptor!.runtimeKind, 'module');
      await manager.select(imported.descriptor!.id);
      final source = (await manager.open(imported.descriptor!.id))!;
      expect((await source.categories()).single.title, '电影');
      expect((await source.list(keyword: '搜索')).items.single.title, '搜索');
      expect((await source.detail('1'))!.title, '详情');
      final chapter = (await source.chapters('1')).single;
      final content = (await source.content(
        itemId: '1',
        chapterId: chapter.id,
      )) as VideoContent;
      expect(content.url.path, '/video.mp4');
      expect(content.headers['Referer'], 'https://example.org/');
      SourceRegistry.close(Section.video);
      expect((await manager.open(imported.descriptor!.id))!.name, '模块 $style');
    }, skip: available ? null : 'QuickJS 原生桥不可用');
  }
}
