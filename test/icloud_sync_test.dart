import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/cloud_merge.dart';
import 'package:lume_box/core/session/icloud_sync.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/reading/reading.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('record merges are deterministic, preserve deletion tombstones and validate format', () {
    final a = {
      'a': {
        'stamp': 1,
        'device': 'a',
        'value': {'title': 'old'},
      },
    };
    final b = {
      'a': {'stamp': 2, 'device': 'b', 'value': null},
      'b': {'stamp': 2, 'device': 'b', 'value': 'keep'},
    };
    final merged = CloudMerge.merge([a, b]);
    expect(merged['a']!['value'], isNull);
    expect(merged['b']!['value'], 'keep');
    expect(CloudMerge.merge([b, a]), merged);
    expect(CloudMerge.decode(CloudMerge.encode(merged)), merged);
    expect(() => CloudMerge.decode('{"version":999}'), throwsFormatException);
  });
  late Directory root;
  late ICloudSync cloud;
  late ReadingLibrary library;
  var documents = <String>[];
  var uploads = 0;
  var account = 'account-a';
  var fail = false;
  var failWrite = false;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume-icloud-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    messenger.setMockMethodCallHandler(ICloudSync.channel, (call) async {
      if (fail) {
        throw PlatformException(code: 'icloud', message: 'iCloud 正在下载同步数据');
      }
      if (call.method == 'read') {
        return {'account': account, 'documents': documents};
      }
      if (call.method == 'write') {
        if (failWrite) {
          throw PlatformException(code: 'icloud', message: 'iCloud 写入失败');
        }
        uploads++;
        documents = [(call.arguments as Map)['text'] as String];
        return true;
      }
      return {'available': true, 'account': account};
    });
    uploads = 0;
    documents = [];
    account = 'account-a';
    fail = false;
    failWrite = false;
    library = await ReadingLibrary.open(Section.video);
    cloud = ICloudSync(platformSupported: true, directory: root)
      ..includeSettings = false
      ..includeSubscriptions = false;
    await cloud.boot();
  });
  tearDown(() async {
    cloud.dispose();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    messenger.setMockMethodCallHandler(ICloudSync.channel, null);
    root.deleteSync(recursive: true);
  });
  test('two device records merge, favorites deletion propagates, and sync persists', () async {
    library.shelve(
      sourceId: 'source-a',
      itemId: 'local',
      title: '本机作品',
      chapterCount: 2,
    );
    final store = await ReadingStore.open(Section.video);
    final localRow = Map<String, Object?>.from(
      store.cloudRecords(includeSettings: false)[jsonEncode([
            'video',
            'library_item',
            'local',
          ])]
          as Map,
    );
    final remoteKey = jsonEncode(['video', 'library_item', 'remote']);
    documents = [
      CloudMerge.encode({
        remoteKey: {
          'stamp': 1,
          'device': 'remote-device',
          'value': {...localRow, 'item_id': 'remote', 'title': '云端作品'},
        },
      }),
    ];
    await cloud.sync();
    expect(uploads, 1);
    expect(
      library.shelf().map((item) => item.itemId),
      containsAll(['local', 'remote']),
    );
    library.removeFavorite('remote');
    await cloud.sync();
    expect(library.onShelf('remote'), false);
    final records = CloudMerge.decode(documents.single);
    expect((records[remoteKey]!['value'] as Map)['favorite'], 0);
    expect(File('${root.path}/icloud-sync-local.json').existsSync(), true);
    fail = true;
    await cloud.sync();
    expect(uploads, 2);
    expect(library.onShelf('local'), true);
    expect(cloud.status, contains('下载'));
  });
  test(
    'cloud write failure leaves local favorite and settings unchanged',
    () async {
      library.shelve(
        sourceId: 'source-a',
        itemId: 'local',
        title: '本机作品',
        chapterCount: 2,
      );
      final store = await ReadingStore.open(Section.video);
      final key = jsonEncode(['video', 'library_item', 'local']);
      final row = Map<String, Object?>.from(
        store.cloudRecords(includeSettings: false)[key] as Map,
      );
      documents = [
        CloudMerge.encode({
          key: {
            'stamp': 1,
            'device': 'other',
            'value': {...row, 'title': '云端覆盖标题'},
          },
        }),
      ];
      failWrite = true;
      await cloud.sync();
      expect(library.item('local')!.title, '本机作品');
      expect(cloud.busy, false);
      expect(cloud.status, contains('写入失败'));
      expect(uploads, 0);
    },
  );

  test('account change pauses automatic sync before any upload', () async {
    library.shelve(
      sourceId: 'source-a',
      itemId: 'local',
      title: '本机作品',
      chapterCount: 2,
    );
    await cloud.sync();
    account = 'account-b';
    cloud.automatic = true;
    await cloud.sync();
    expect(uploads, 1);
    expect(cloud.automatic, false);
    expect(cloud.status, contains('账号已变化'));
    expect(library.onShelf('local'), true);
  });
  test(
    'cloud rows reject cross-section data without mutating the library',
    () async {
      final store = await ReadingStore.open(Section.video);
      expect(
        () => store.applyCloudRecords({
          jsonEncode(['comic', 'reading_setting', 'favorites.folders']): {
            'key': 'favorites.folders',
            'value': '{}',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => store.applyCloudRecords({
          jsonEncode(['video', 'reading_setting', 'waf.cookies']): {
            'key': 'waf.cookies',
            'value': 'secret',
          },
        }),
        throwsFormatException,
      );
      expect(store.setting('waf.cookies'), isNull);
    },
  );
}
