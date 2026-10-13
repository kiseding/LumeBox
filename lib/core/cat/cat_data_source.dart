import 'dart:convert';
import 'dart:io';

import '../session/section.dart';
import '../source/source.dart';
import 'cat_service.dart';

String catUnescape(String value) {
  const pairs = {
    '＄': r'$',
    '＃': '#',
    '＠': '@',
    '｜': '|',
    '：': ':',
    '＆': '&',
    '＝': '=',
    '？': '?',
  };
  for (final pair in pairs.entries) {
    value = value.replaceAll(pair.key, pair.value);
  }
  return value;
}

class CatDataSource
    implements DataSource, HomeCapable, FilterCapable, ContextualFilterCapable {
  CatDataSource(this.service, this.site);
  final CatService service;
  final CatSite site;
  Map<String, dynamic>? _home;
  final _details = <String, Map<String, dynamic>>{};
  final _folders = <String>{};
  bool isFolder(String itemId) => _folders.contains(itemId);
  @override
  String get id => site.id;
  @override
  String get name => site.name;
  @override
  Section get section => switch (site.kind) {
    'comic' => Section.comic,
    'novel' => Section.novel,
    _ => Section.video,
  };
  Future<Map<String, dynamic>> homeData({bool force = false}) async {
    if (force) _home = null;
    return _home ??= await service.call(site, 'home');
  }

  @override
  Future<bool> supportsHome() async => true;
  @override
  Future<bool> supportsFilters() async => true;
  @override
  Future<List<SourceCategory>> categories() async =>
      catMaps((await homeData())['class'])
          .map(
            (raw) => SourceCategory(
              id: catText(raw['type_id'] ?? raw['id']),
              title: catText(raw['type_name'] ?? raw['name']),
            ),
          )
          .where((category) => category.id.isNotEmpty)
          .toList();
  @override
  Future<List<SourceFilterGroup>> filters() => filtersFor();
  @override
  Future<List<SourceFilterGroup>> filtersFor({
    String? categoryId,
    Map<String, String>? selection,
  }) async {
    final raw = catMap((await homeData())['filters']);
    final categories = await this.categories();
    final tid = categoryId ?? categories.firstOrNull?.id;
    return catMaps(raw[tid])
        .map(
          (group) => SourceFilterGroup(
            id: catText(group['key'] ?? group['id']),
            title: catText(group['name'] ?? group['title']),
            options: catMaps(group['value'] ?? group['options'])
                .map(
                  (option) => SourceFilterOption(
                    id: catText(option['v'] ?? option['id']),
                    title: catText(option['n'] ?? option['title']),
                  ),
                )
                .toList(),
          ),
        )
        .where((group) => group.id.isNotEmpty && group.options.isNotEmpty)
        .toList();
  }

  Uri? address(String value) {
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(catUnescape(value));
    if (uri == null) return null;
    if (uri.hasScheme) {
      final base = service.baseFor(site);
      if (base != null && ['127.0.0.1', 'localhost'].contains(uri.host)) {
        return uri.replace(host: base.host, port: base.port);
      }
      return uri;
    }
    return service.baseFor(site)?.resolveUri(uri);
  }

  Map<String, String> headers(Object? value) =>
      catMap(value).map((key, value) => MapEntry(key, catText(value)));
  SourceItem? item(Map<String, dynamic> raw) {
    final id = catText(
      raw['vod_id'] ?? raw['book_id'] ?? raw['comic_id'] ?? raw['id'],
    );
    final title = catText(
      raw['vod_name'] ??
          raw['book_name'] ??
          raw['comic_name'] ??
          raw['name'] ??
          raw['title'],
    );
    if (id.isEmpty || title.isEmpty) return null;
    final scopedId = jsonEncode([site.id, id]);
    if (raw['vod_tag'] == 'folder' ||
        raw['is_dir'] == true ||
        raw['isFolder'] == true) {
      _folders.add(scopedId);
    }
    final cover = address(
      catText(
        raw['vod_pic'] ??
            raw['book_pic'] ??
            raw['comic_pic'] ??
            raw['pic'] ??
            raw['cover'],
      ),
    );
    return SourceItem(
      id: scopedId,
      title: title,
      cover: cover?.toString(),
      subtitle: catText(
        raw['vod_remarks'] ?? raw['book_remarks'] ?? raw['remarks'],
      ),
      coverHeaders: {
        ...?service.imageHeadersFor(site),
        ...headers(raw['pic_headers'] ?? raw['coverHeaders']),
      },
    );
  }

  List<SourceItem> items(Map<String, dynamic> payload) =>
      catMaps(payload['list'] ?? payload['items'])
          .map(item)
          .whereType<SourceItem>()
          .toList();
  @override
  Future<SourceHome> home() async {
    return SourceHome(items: (await homeList()).items);
  }

  Future<SourceList> homeList() async {
    final data = await homeData();
    var found = items(data);
    if (found.isEmpty) {
      try {
        found = items(await service.call(site, 'homeVod'));
      } on HttpException {
        /* Some sources only provide category(). */
      }
    }
    if (found.isEmpty) return list();
    return SourceList(items: found, hasMore: false);
  }

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    final Map<String, dynamic> data;
    if (keyword != null && keyword.trim().isNotEmpty) {
      data = await service.call(site, 'search', {
        'wd': keyword.trim(),
        'pg': '$page',
        'quick': false,
      });
    } else {
      final tid = categoryId ?? (await categories()).firstOrNull?.id ?? '';
      data = await service.call(site, 'category', {
        'tid': tid,
        'pg': '$page',
        'filter': filters?.isNotEmpty == true,
        'extend': filters ?? {},
      });
    }
    final found = items(data);
    final pages = int.tryParse(catText(data['pagecount'] ?? data['pageCount']));
    return SourceList(
      items: found,
      hasMore: pages == null ? found.length >= 20 : page < pages,
    );
  }

  String rawItemId(String itemId) {
    try {
      final value = jsonDecode(itemId);
      if (value is List && value.length == 2 && value.first == site.id) {
        return catText(value.last);
      }
    } catch (_) {}
    return itemId;
  }

  Future<Map<String, dynamic>> rawDetail(String itemId) async =>
      _details[itemId] ??=
          catMaps(
            (await service.call(site, 'detail', {
              'id': rawItemId(itemId),
            }))['list'],
          ).firstOrNull ??
          {};
  @override
  Future<SourceDetail?> detail(String itemId) async {
    final raw = await rawDetail(itemId);
    final entry = item(raw);
    if (entry == null) return null;
    return SourceDetail(
      id: entry.id,
      title: entry.title,
      cover: entry.cover,
      coverHeaders: entry.coverHeaders,
      subtitle: entry.subtitle,
      description: catText(
        raw['vod_content'] ?? raw['book_content'] ?? raw['description'],
      ).replaceAll(RegExp(r'<[^>]+>'), '').trim(),
    );
  }

  static List<SourceChapter> parseChapters(Map<String, dynamic> raw) {
    final explicit = catMaps(raw['chapters'] ?? raw['book_chapters']);
    if (explicit.isNotEmpty) {
      return explicit
          .map(
            (entry) => SourceChapter(
              id: jsonEncode({
                'flag': catText(entry['flag']),
                'id': catText(entry['id'] ?? entry['url']),
              }),
              title: catText(entry['title'] ?? entry['name']),
            ),
          )
          .toList();
    }
    final flags = catText(raw['vod_play_from'] ?? raw['book_play_from'])
        .split(r'$$$');
    final lines = catText(raw['vod_play_url'] ?? raw['book_play_url'])
        .split(r'$$$');
    final chapters = <SourceChapter>[];
    for (var index = 0; index < lines.length; index++) {
      final flag = index < flags.length ? flags[index] : '';
      for (final part in lines[index].split('#')) {
        if (part.trim().isEmpty) continue;
        final split = part.indexOf(r'$');
        final label = split >= 0 ? part.substring(0, split) : '播放';
        final target = split >= 0 ? part.substring(split + 1) : part;
        chapters.add(
          SourceChapter(
            id: jsonEncode({
              'flag': catUnescape(flag),
              'id': catUnescape(target),
            }),
            title: flags.length > 1 ? '$flag · $label' : label,
          ),
        );
      }
    }
    return chapters;
  }

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      parseChapters(await rawDetail(itemId));
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    final episode = catMap(jsonDecode(chapterId));
    final data = await service.call(site, 'play', {
      'flag': episode['flag'] ?? '',
      'id': episode['id'],
      'flags': [],
    });
    final requestHeaders = headers(data['header'] ?? data['headers']);
    if (site.kind == 'comic') {
      var images = data['images'] ?? data['urls'] ?? data['list'];
      if (images is String) {
        try {
          images = jsonDecode(images);
        } catch (_) {}
      }
      if (images is List) {
        final urls = images
            .map(
              (value) => address(
                value is Map ? catText(value['url']) : catText(value),
              ),
            )
            .whereType<Uri>()
            .map((uri) => uri.toString())
            .toList();
        return ImageContent(
          urls,
          imageHeaders: {for (final url in urls) url: requestHeaders},
        );
      }
    }
    if (site.kind == 'novel') {
      return TextContent(catText(data['content'] ?? data['text']));
    }
    final uri = address(catText(data['url']));
    if (data['parse'] == 1 || data['parse'] == '1') {
      throw StateError('站点返回网页解析地址，请换一条直连线路');
    }
    if (uri == null ||
        !['http', 'https', 'rtmp', 'rtsp'].contains(uri.scheme)) {
      throw StateError('站点未返回可播放地址');
    }
    return ChapterContent.parse({
      'kind': 'video',
      'url': uri.toString(),
      'headers': requestHeaders,
      'qualities': data['qualities'] ?? data['levels'],
    })!;
  }
}

/// The player/readers use this port to reopen their own Cat site. Management is
/// handled by Cat subscription UI, never the ordinary QuickJS source registry.
class CatSourceManager implements SourceManager {
  CatSourceManager(this.service, this.site);
  final CatService service;
  final CatSite site;
  @override
  bool get runtimeAvailable => true;
  @override
  Future<DataSource?> open(String sourceId) async =>
      sourceId == site.id ? CatDataSource(service, site) : null;
  @override
  Future<List<SourceDescriptor>> list() async => [
    SourceDescriptor(
      id: site.id,
      name: site.name,
      version: 'Node',
      enabled: true,
    ),
  ];
  @override
  Future<SourceDescriptor?> current() async => (await list()).first;
  @override
  Future<SourceDescriptor?> select(String sourceId) async =>
      sourceId == site.id ? current() : null;
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('请在猫源订阅管理中操作');
}
