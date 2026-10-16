import 'dart:convert';

import '../reading/reading_library.dart';
import '../session/section.dart';

/// Stable order shared by the manager and source picker, scoped to a section.
class SourceOrder {
  static const key = 'source.display.order';
  static List<String> read(Section section) {
    try {
      final raw = ReadingLibrary.find(section)?.setting(key);
      return raw == null ? [] : (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  static int compare(
    Section section,
    String a,
    String b,
    List<String> fallback,
  ) {
    final saved = read(section);
    final order = [...saved, ...fallback.where((id) => !saved.contains(id))];
    return order.indexOf(a).compareTo(order.indexOf(b));
  }

  static Future<void> move(
    Section section,
    List<String> all,
    List<String> visible,
    int from,
    int to,
  ) async {
    if (from == to) return;
    if (from < 0 || from >= visible.length || to < 0 || to >= visible.length) {
      return;
    }
    final reordered = List<String>.of(visible);
    reordered.insert(to, reordered.removeAt(from));
    final selected = visible.toSet();
    var index = 0;
    final complete = [
      ...all,
      ...read(section).where((id) => !all.contains(id)),
    ];
    final merged = complete
        .map((id) => selected.contains(id) ? reordered[index++] : id)
        .toList();
    final library = await ReadingLibrary.open(section);
    library.setSetting(key, jsonEncode(merged));
  }
}
