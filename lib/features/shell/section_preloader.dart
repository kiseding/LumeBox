import 'dart:async';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';

/// One bounded, shared request per section. Explicit refresh invalidates in-flight results.
class SectionPreloader {
  SectionPreloader._();
  static const ttl = Duration(seconds: 60);
  static final _warm = <Section, _WarmEntry>{};
  static final _tasks = <Section, Future<void>>{};
  static final _generation = <Section, int>{};

  static Future<void> warm(
    Section section, {
    SourceManager? manager,
    Future<void> Function()? openLibrary,
  }) {
    final existing = _tasks[section];
    if (existing != null) return existing;
    final generation = _generation[section] ?? 0;
    late Future<void> task;
    task = _perform(section, manager, openLibrary, generation)
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () {
            if ((_generation[section] ?? 0) == generation) discard(section);
          },
        )
        .whenComplete(() {
          if (identical(_tasks[section], task)) _tasks.remove(section);
        });
    _tasks[section] = task;
    return task;
  }

  static Future<void> _perform(
    Section section,
    SourceManager? manager,
    Future<void> Function()? openLibrary,
    int generation,
  ) async {
    try {
      await openLibrary?.call();
      if (manager == null || !manager.runtimeAvailable) return;
      final current = await manager.current();
      if (current == null) return;
      final cached = _valid(section, current.id);
      if (cached != null) return;
      final source = await manager.open(current.id);
      if (source == null) return;
      SourceHome? home;
      SourceList? list;
      if (source is HomeCapable &&
          await (source as HomeCapable).supportsHome()) {
        home = await (source as HomeCapable).home();
      } else {
        list = await source.list(page: 1);
      }
      if ((_generation[section] ?? 0) != generation) return;
      _warm[section] = _WarmEntry(source.id, list, home);
    } catch (error) {
      LumeLog.info('[warm] ${section.id} 预热失败，页面可正常重试：$error');
    }
  }

  static Future<void> waitForWarm(Section section) async {
    final task = _tasks[section];
    if (task != null) {
      await task.timeout(const Duration(seconds: 3), onTimeout: () {});
    }
  }

  static _WarmEntry? _valid(Section section, String sourceId) {
    final entry = _warm[section];
    if (entry == null || entry.sourceId != sourceId) return null;
    if (DateTime.now().difference(entry.at) > ttl) {
      _warm.remove(section);
      return null;
    }
    return entry;
  }

  static SourceList? takeWarmPage(
    Section section, {
    required String sourceId,
    String? categoryId,
    String keyword = '',
  }) {
    if (categoryId != null || keyword.isNotEmpty) return null;
    final entry = _valid(section, sourceId);
    if (entry?.list == null) return null;
    _warm.remove(section);
    return entry!.list;
  }

  static SourceHome? takeWarmHome(Section section, {required String sourceId}) {
    final entry = _valid(section, sourceId);
    if (entry?.home == null) return null;
    _warm.remove(section);
    return entry!.home;
  }

  static void discard([Section? section]) {
    for (final target in section == null ? Section.values : [section]) {
      _warm.remove(target);
      _tasks.remove(target);
      _generation[target] = (_generation[target] ?? 0) + 1;
    }
  }

  static bool hasWarm(Section section) => _warm.containsKey(section);
}

class _WarmEntry {
  _WarmEntry(this.sourceId, this.list, this.home);
  final String sourceId;
  final SourceList? list;
  final SourceHome? home;
  final at = DateTime.now();
}
