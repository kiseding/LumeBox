import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../source/source.dart';
import '../net/waf.dart';
import '../net/source_request_log.dart';
import '../session/section.dart';
import '../audio_book/audio_book_track.dart';
import 'media_library.dart';

class MediaResourceService {
  MediaResourceService({
    this.probe = const MediaTrackProbe(),
    MediaLibrary? library,
  }) : library = library ?? MediaLibrary.instance;
  final MediaTrackProbe probe;
  final MediaLibrary library;
  static Uri? address(ChapterContent? content) {
    if (content is VideoContent) return content.url;
    if (content is TextContent) {
      final value = Uri.tryParse(content.text.trim());
      if (value != null &&
          ['http', 'https', 'file'].contains(value.scheme) &&
          RegExp(
            r'\.(mp3|m4a|aac|flac|ogg|opus|wav|mp4|mkv|m3u8)$',
            caseSensitive: false,
          ).hasMatch(value.path)) {
        return value;
      }
    }
    return null;
  }

  static Map<String, String> headers(
    ChapterContent? content, {
    DataSource? source,
  }) {
    final result = content is VideoContent
        ? Map<String, String>.of(content.headers)
        : <String, String>{};
    if (source == null) return result;
    final ua =
        WafSessions.userAgentFor(source.section, source.id)?.trim() ?? '';
    final url = address(content);
    final cookie =
        url != null && SourceRequestLog.ownsHost(source.id, url.toString())
        ? WafSessions.cookiesFor(source.section, source.id)?.trim() ?? ''
        : '';
    if (ua.isNotEmpty) {
      result.removeWhere((key, _) => key.toLowerCase() == 'user-agent');
      result['User-Agent'] = ua;
    }
    if (cookie.isNotEmpty &&
        !result.keys.any((key) => key.toLowerCase() == 'cookie')) {
      result['Cookie'] = cookie;
    }
    return result;
  }

  Future<MediaResource> source({
    required DataSource source,
    required SourceItem item,
    required List<SourceChapter> chapters,
    ResourceKind? hint,
    ChapterContent? firstContent,
  }) async {
    await library.boot();
    final id = MediaResource.sourceKey(source.section, source.id, item.id);
    final previous = library.byId(id);
    if (previous?.manual == true) return previous!;
    final content =
        firstContent ??
        (chapters.isEmpty
            ? null
            : await source.content(
                itemId: item.id,
                chapterId: chapters.first.id,
              ));
    final uri = address(content);
    final tracks = uri == null
        ? const MediaTrackInfo()
        : await probe.inspect(uri, headers: headers(content, source: source));
    final kind =
        tracks.kind ??
        (content is TextContent && uri == null
            ? ResourceKind.novel
            : content is VideoContent && content.audioOnly ||
                  uri != null &&
                      RegExp(
                        r'\.(mp3|m4a|aac|flac|ogg|opus|wav)$',
                        caseSensitive: false,
                      ).hasMatch(uri.path)
            ? ResourceKind.audioBook
            : hint) ??
        (source.section == Section.novel
            ? ResourceKind.audioBook
            : ResourceKind.video);
    return library.add(
      MediaResource(
        id: id,
        title: item.title,
        kind: kind,
        destination: kind.defaultSection,
        originSection: source.section,
        sourceId: source.id,
        itemId: item.id,
        cover: item.cover,
        episodes: [
          for (final chapter in chapters)
            ResourceEpisode(id: chapter.id, title: chapter.title),
        ],
      ),
    );
  }

  Future<MediaResource> file(
    File input, {
    required String name,
    ResourceKind? chosen,
  }) async {
    final support = await getApplicationSupportDirectory();
    final id = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final target = File(
      '${support.path}/media/$id/${Uri.encodeComponent(name)}',
    );
    await target.parent.create(recursive: true);
    await input.copy(target.path);
    final text = name.toLowerCase().endsWith('.txt');
    final tracks = text
        ? const MediaTrackInfo()
        : await probe.inspect(target.uri);
    final hint =
        RegExp(
          r'\.(mp3|m4a|aac|flac|ogg|opus|wav)$',
          caseSensitive: false,
        ).hasMatch(name)
        ? ResourceKind.audioBook
        : ResourceKind.video;
    final kind = chosen ?? (text ? ResourceKind.novel : tracks.kind ?? hint);
    return library.add(
      MediaResource(
        id: id,
        title: name,
        kind: kind,
        destination: kind.defaultSection,
        manual: chosen != null,
        textPath: text ? target.path : null,
        episodes: [ResourceEpisode(id: id, title: name, url: target.uri)],
      ),
    );
  }

  Future<ResolvedAudio> resolve(
    MediaResource resource,
    ResourceEpisode episode,
  ) async {
    if (episode.url != null) {
      return ResolvedAudio(episode.url!, headers: episode.headers);
    }
    final section = resource.originSection,
        sourceId = resource.sourceId,
        item = resource.itemId;
    if (section == null || sourceId == null || item == null) {
      throw StateError('缺少源引用');
    }
    final source = await LumeSources.manager(section).open(sourceId);
    if (source == null) throw StateError('源不可用');
    final content = await source.content(itemId: item, chapterId: episode.id);
    final uri = address(content);
    if (uri == null) throw StateError('源没有返回媒体地址');
    return ResolvedAudio(uri, headers: headers(content, source: source));
  }

  List<AudioBookTrack> audioTracks(MediaResource resource) => [
    for (final episode in resource.episodes)
      AudioBookTrack(
        id: '${resource.id}:${episode.id}',
        album: resource.title,
        cover: resource.cover,
        episode: episode,
        resolve: () => resolve(resource, episode),
      ),
  ];
}
