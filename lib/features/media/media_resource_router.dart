import '../../core/media/playback_focus.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/media/media_library.dart';
import '../../core/media/media_resource_service.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/player/abstract_player.dart';
import '../audio_book/audio_book_page.dart';
import '../novel/novel_reader_page.dart';
import '../video/video_player_page.dart';
import '../video/player_choice.dart';

Future<void> openMediaResource(
  BuildContext context,
  MediaResource entry, {
  int? index,
}) async {
  if (entry.episodes.isEmpty) throw StateError('资源没有章节');
  final service = MediaResourceService();
  if (entry.kind == ResourceKind.audioBook) {
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => AudioBookPage(
          resource: entry,
          tracks: service.audioTracks(entry),
          initialIndex: index,
        ),
      ),
    );
    return;
  }
  if (entry.kind == ResourceKind.video) {
    await PlaybackFocus.acquire('video');
    final media = await service.resolve(entry, entry.episodes[index ?? 0]);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerChoiceRoute(
          original: VideoPlayerPage(
            media: PlayerMedia(
              uri: media.url,
              headers: media.headers,
              title: entry.title,
            ),
            title: entry.title,
          ),
        ),
      ),
    );
    return;
  }
  final DataSource? source = entry.textPath != null
      ? _LocalTextSource(entry)
      : entry.originSection != null && entry.sourceId != null
      ? await LumeSources.manager(entry.originSection!).open(entry.sourceId!)
      : null;
  if (source == null) throw StateError('文字源不可用');
  final text = await source.content(
    itemId: entry.itemId ?? entry.id,
    chapterId: entry.episodes[index ?? 0].id,
  );
  if (text is! TextContent || MediaResourceService.address(text) != null) {
    throw StateError('这不是小说正文，请将成品音频设为有声小说');
  }
  final library = await ReadingLibrary.open(Section.novel);
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => NovelReaderPage(
        library: library,
        dataSource: source,
        target: ReadingTarget(
          sourceId: entry.sourceId ?? 'local-text',
          itemId: entry.itemId ?? entry.id,
          title: entry.title,
          cover: entry.cover,
        ),
        chapters: [
          for (final episode in entry.episodes)
            SourceChapter(id: episode.id, title: episode.title),
        ],
        initialChapterIndex: index ?? 0,
      ),
    ),
  );
}

class _LocalTextSource implements DataSource {
  _LocalTextSource(this.resource);
  final MediaResource resource;
  @override
  String get id => 'local-text';
  @override
  String get name => '本地文字小说';
  @override
  Section get section => Section.novel;
  @override
  Future<List<SourceCategory>> categories() async => [];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList();
  @override
  Future<SourceDetail?> detail(String itemId) async =>
      SourceDetail(id: itemId, title: resource.title);
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => [
    SourceChapter(id: resource.id, title: resource.title),
  ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => TextContent(await File(resource.textPath!).readAsString());
}
