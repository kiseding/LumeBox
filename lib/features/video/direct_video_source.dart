import '../../core/source/source.dart';
import '../../core/session/section.dart';

/// One media capture from a web home. It exposes only data the page supplied.
class DirectVideoSource implements DataSource {
  DirectVideoSource({
    required this.id,
    required this.name,
    required this.title,
    required this.uri,
    this.headers = const {},
  });
  @override
  final String id, name;
  final String title;
  final Uri uri;
  final Map<String, String> headers;
  @override
  Section get section => Section.video;
  @override
  Future<List<SourceCategory>> categories() async => [];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(items: [], hasMore: false);
  @override
  Future<SourceDetail?> detail(String itemId) async =>
      SourceDetail(id: itemId, title: title, subtitle: name);
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => [
    SourceChapter(id: uri.toString(), title: '正片'),
  ];
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => VideoContent(url: uri, headers: headers);
}
