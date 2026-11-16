import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/music/music_library.dart';
import 'package:lume_box/core/music/music_models.dart';
import 'package:lume_box/core/music/music_service.dart';

class _CatalogService extends MusicService {
  _CatalogService({required super.library});
  List<MusicTrack> rows = [];
  Completer<void>? gate;
  int calls = 0;
  @override
  Future<MusicSearchResult> search(
    String keyword, {
    int page = 1,
    String? pluginId,
    String? platform,
  }) async {
    calls++;
    await gate?.future;
    return MusicSearchResult(rows);
  }
}

void main() {
  late Directory root;
  late MusicLibrary library;
  late _CatalogService service;
  const track = MusicTrack(
    pluginId: 'p',
    platform: 'wy',
    id: 'one',
    title: '海',
    artist: '任东',
  );
  MusicTrack candidate({
    String id = 'two',
    String title = '海',
    String artist = '任东',
    String plugin = 'p',
    String cover = 'https://example.com/cover.jpg',
  }) => MusicTrack(
    pluginId: plugin,
    platform: 'wy',
    id: id,
    title: title,
    artist: artist,
    cover: cover,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('music-artwork-');
    library = MusicLibrary(directory: root);
    await library.load();
    library.plugins.add(
      const MusicPlugin(id: 'p', name: 'source', protocol: MusicProtocol.lx),
    );
    service = _CatalogService(library: library);
  });
  tearDown(() async {
    service.dispose();
    await library.save();
    library.dispose();
    await root.delete(recursive: true);
  });

  test('歌曲 ID 优先，补封面不改变原始播放标识，地址保存到队列收藏历史', () async {
    service.rows = [
      candidate(),
      candidate(id: 'one', cover: 'https://example.com/id.jpg'),
    ];
    final cover = await service.artwork(track);
    expect(cover, 'https://example.com/id.jpg');
    final updated = track.withCover(cover!);
    expect(updated.key, track.key);
    expect(updated.raw, same(track.raw));
    library.queue.add(track);
    library.recent.add(track);
    library.favorites.add(track);
    await library.rememberArtwork(updated);
    final restored = MusicLibrary(directory: root);
    await restored.load();
    for (final list in [restored.queue, restored.recent, restored.favorites]) {
      expect(list.single.cover, cover);
      expect(list.single.key, track.key);
    }
    restored.dispose();
  });
  test('无 ID 命中时接受唯一歌名歌手匹配，拒绝伴奏和不同歌手', () async {
    service.rows = [
      candidate(title: '海（伴奏）'),
      candidate(artist: '其他歌手'),
      candidate(),
    ];
    expect(await service.artwork(track), 'https://example.com/cover.jpg');
  });
  test('不同源、同名多版本和缺歌手时不借用封面', () async {
    service.rows = [
      candidate(plugin: 'other'),
      candidate(),
      candidate(id: 'three', cover: 'https://example.com/other.jpg'),
    ];
    expect(await service.artwork(track), isNull);
    expect(
      await service.artwork(
        const MusicTrack(
          pluginId: 'p',
          platform: 'wy',
          id: 'unknown',
          title: '海',
        ),
      ),
      isNull,
    );
  });
  test('重复补查合并在途请求并缓存结果', () async {
    service.rows = [candidate()];
    service.gate = Completer<void>();
    final first = service.artwork(track), second = service.artwork(track);
    await Future<void>.delayed(Duration.zero);
    expect(service.calls, 1);
    service.gate!.complete();
    expect(await first, await second);
    await service.artwork(track);
    expect(service.calls, 1);
  });
  test('从原始专辑资料补全，无效字段不遮住后面的有效地址', () async {
    final parsed = MusicTrack.parse('p', {
      'id': 'a',
      'title': '海',
      'artwork': {},
      'cover': '',
      'album': {'name': '海', 'picUrl': '//example.com/album.jpg'},
    });
    expect(parsed.cover, 'https://example.com/album.jpg');
    expect(await service.artwork(parsed), parsed.cover);
    expect(service.calls, 0);
    expect(MusicTrack.artworkUrl('file:///private/cover'), isNull);
    expect(MusicTrack.artworkUrl('javascript:alert(1)'), isNull);
  });
}
