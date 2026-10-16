import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/media/media_resource_service.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/fake_reading_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MediaLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lume-media-test-');
    library = MediaLibrary();
    await library.boot(directory: root);
  });
  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });
  test(
    'real audio-only tracks override video origin and misleading filename',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('lumebox/mediaTracks'),
            (_) async => {'known': true, 'audio': true, 'video': false},
          );
      final entry = await MediaResourceService(library: library).source(
        source: FakeReadingDataSource(section: Section.video),
        item: const SourceItem(id: 'audio', title: '有声书'),
        chapters: const [SourceChapter(id: '1', title: '第1集')],
        firstContent: VideoContent(
          url: Uri.parse('https://audio.example/misleading.mp4'),
        ),
      );
      expect(entry.kind, ResourceKind.audioBook);
      expect(entry.destination, Section.novel);
      expect(entry.originSection, Section.video);
      expect(entry.manual, false);
    },
  );
  test('video track wins even when file is named mp3', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lumebox/mediaTracks'),
          (_) async => {'known': true, 'audio': true, 'video': true},
        );
    final entry = await MediaResourceService(library: library).source(
      source: FakeReadingDataSource(section: Section.novel),
      item: const SourceItem(id: 'video', title: '视频'),
      chapters: const [SourceChapter(id: '1', title: '第1集')],
      firstContent: VideoContent(
        url: Uri.parse('https://video.example/misleading.mp3'),
        audioOnly: true,
      ),
    );
    expect(entry.kind, ResourceKind.video);
    expect(entry.destination, Section.video);
  });
  test(
    'manual migration survives detection and reopen without rewriting origin',
    () async {
      const item = SourceItem(id: 'manual', title: '可迁移');
      final source = FakeReadingDataSource(section: Section.video);
      final service = MediaResourceService(library: library);
      final entry = await service.source(
        source: source,
        item: item,
        chapters: const [SourceChapter(id: 'c', title: '章节')],
        firstContent: const TextContent('这是真正的小说正文。'),
      );
      expect(entry.kind, ResourceKind.novel);
      expect(entry.destination, Section.novel);
      final moved = await library.move(
        entry.id,
        ResourceKind.audioBook,
        Section.video,
      );
      expect(moved.manual, true);
      expect(moved.originSection, Section.video);
      final rediscovered = await service.source(
        source: source,
        item: item,
        chapters: const [],
        firstContent: const TextContent('正文仍然不变'),
      );
      expect(rediscovered.kind, ResourceKind.audioBook);
      expect(rediscovered.destination, Section.video);
      final updated = await service.source(
        source: source,
        item: item,
        chapters: const [SourceChapter(id: 'new', title: '更新章节')],
      );
      expect(updated.kind, ResourceKind.audioBook);
      expect(updated.destination, Section.video);
      expect(updated.episodes.single.id, 'new');
      final reopened = MediaLibrary();
      await reopened.boot(directory: root);
      expect(reopened.byId(entry.id)!.kind, ResourceKind.audioBook);
      await reopened.move(entry.id, ResourceKind.audioBook, Section.novel);
      expect(
        reopened.visibleAtOrigin(Section.video, source.id, item.id),
        false,
      );
      expect(reopened.entries(Section.novel).single.itemId, item.id);
      reopened.dispose();
    },
  );
  test('audio payload kinds retain audio classification hint', () {
    final content = ChapterContent.parse({
      'kind': 'audio',
      'url': 'https://example.com/audio',
    });
    expect(content, isA<VideoContent>());
    expect((content as VideoContent).audioOnly, true);
    expect(
      const MediaTrackInfo(known: true, audio: true).kind,
      ResourceKind.audioBook,
    );
    expect(const MediaTrackInfo().kind, null);
  });
}
