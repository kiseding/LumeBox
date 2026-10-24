import 'dart:convert';

import '../../core/source/source.dart';

/// Route grouping never rewrites chapter IDs: the original source still resolves them.
abstract final class VideoEpisodeCatalog {
  static Future<List<SourceChapter>> load(
    DataSource source,
    String itemId,
  ) async {
    try {
      final chapters = await source.chapters(itemId);
      if (chapters.isNotEmpty) return chapters;
    } catch (_) {
      final metadata = await source.detail(itemId);
      if (metadata?.chapters.isNotEmpty == true) return metadata!.chapters;
      rethrow;
    }
    return (await source.detail(itemId))?.chapters ?? [];
  }

  static String lineOf(SourceChapter chapter) {
    if (chapter.line.trim().isNotEmpty) return chapter.line.trim();
    try {
      final data = jsonDecode(chapter.id);
      if (data is Map &&
          data['flag'] is String &&
          (data['flag'] as String).trim().isNotEmpty) {
        return (data['flag'] as String).trim();
      }
    } catch (_) {}
    final match = RegExp(r'^(.{1,60}?)\s+[·|｜]\s+(.+)$')
        .firstMatch(chapter.title);
    return match?.group(1)?.trim() ?? '默认线路';
  }

  static String labelOf(SourceChapter chapter) {
    final line = lineOf(chapter);
    final prefix = RegExp('^${RegExp.escape(line)}\\s+[·|｜]\\s+');
    return chapter.title.replaceFirst(prefix, '').trim();
  }

  static Map<String, List<SourceChapter>> group(List<SourceChapter> chapters) {
    final lines = <String, List<SourceChapter>>{};
    for (final chapter in chapters) {
      (lines[lineOf(chapter)] ??= []).add(chapter);
    }
    return lines;
  }

  static List<SourceChapter> forChapter(
    List<SourceChapter> chapters,
    String id,
  ) {
    final selected = chapters.where((c) => c.id == id).firstOrNull;
    if (selected == null) return chapters;
    final line = lineOf(selected);
    return chapters.where((c) => lineOf(c) == line).toList();
  }
}
