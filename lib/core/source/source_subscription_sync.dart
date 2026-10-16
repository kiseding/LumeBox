import '../js/source_script.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../net/lume_http.dart';
import '../net/source_subscription.dart';
import '../session/section.dart';
import '../session/section_scope.dart';
import '../util/lume_log.dart';
import 'source.dart';

class SavedSourceSubscription {
  SavedSourceSubscription(
    this.url, {
    this.enabled = true,
    this.checkedAt,
    this.error = '',
    Map<String, String>? members,
    Set<String>? excludedIds,
  }) : members = members ?? {},
       excludedIds = excludedIds ?? {};
  final String url;
  bool enabled;
  DateTime? checkedAt;
  String error;
  Map<String, String> members;
  final Set<String> excludedIds;
  Map<String, Object?> toJson() => {
    'url': url,
    'enabled': enabled,
    'checkedAt': checkedAt?.toIso8601String(),
    'error': error,
    'members': members,
    'excludedIds': excludedIds.toList(),
  };
}

class SubscriptionSyncResult {
  int added = 0, updated = 0, removed = 0;
  final List<String> errors = [];
  bool get changed => added + updated + removed > 0;
  String get summary =>
      '新增 $added · 更新 $updated · 移除 $removed${errors.isEmpty ? '' : ' · 失败 ${errors.length}'}';
}

/// 地址与清单成员按板块落盘。网络/校验/导入不完整时禁止执行移除。
class SourceSubscriptionSync {
  SourceSubscriptionSync({
    required this.section,
    required this.manager,
    required this.file,
    this.fetch,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final Section section;
  final SourceManager manager;
  final File file;
  final Future<SourceFetchResult> Function(String url)? fetch;
  final DateTime Function() _clock;
  final List<SavedSourceSubscription> subscriptions = [];
  bool _migrated = false;
  static final Map<Section, Future<SubscriptionSyncResult>> _running = {};
  static final Map<Section, ValueNotifier<int>> _revisions = {};
  static final Map<Section, ValueNotifier<int>> _changeCounts = {};
  static final Map<Section, File> _noticeFiles = {};
  static ValueNotifier<int> changeCount(Section section) =>
      _changeCounts.putIfAbsent(section, () {
        final count = ValueNotifier(0);
        count.addListener(() {
          final file = _noticeFiles[section];
          if (file == null) return;
          try {
            file.parent.createSync(recursive: true);
            final temporary = File('${file.path}.tmp');
            temporary.writeAsStringSync('${count.value}', flush: true);
            temporary.renameSync(file.path);
          } catch (error) {
            LumeLog.warn('订阅提示保存失败：$error');
          }
        });
        return count;
      });
  static void attachNoticeFile(Section section, File file) {
    if (_noticeFiles[section]?.path == file.path) return;
    _noticeFiles[section] = file;
    try {
      changeCount(section).value = file.existsSync()
          ? int.tryParse(file.readAsStringSync()) ?? 0
          : 0;
    } catch (_) {
      changeCount(section).value = 0;
    }
  }

  static ValueNotifier<int> revision(Section section) =>
      _revisions.putIfAbsent(section, () => ValueNotifier(0));

  static Future<SourceSubscriptionSync> open(
    Section section, {
    SourceManager? manager,
  }) async {
    final scope = await SectionScope.open(section);
    attachNoticeFile(section, File(scope.resolve('subscription-changes.txt')));
    final service = SourceSubscriptionSync(
      section: section,
      manager: manager ?? LumeSources.manager(section),
      file: File(scope.resolve('subscriptions.json')),
    );
    await service.load();
    if (service.manager.runtimeAvailable) await service._migrate();
    return service;
  }

  Future<void> load() async {
    subscriptions.clear();
    if (!file.existsSync()) return;
    final data = jsonDecode(file.readAsStringSync()) as Map;
    _migrated = data['migrationVersion'] == 3;
    for (final raw in (data['subscriptions'] as List? ?? [])) {
      if (raw is! Map || !_validUrl('${raw['url']}')) continue;
      subscriptions.add(
        SavedSourceSubscription(
          '${raw['url']}',
          enabled: raw['enabled'] != false,
          checkedAt: DateTime.tryParse('${raw['checkedAt']}'),
          error: '${raw['error'] ?? ''}',
          excludedIds: (raw['excludedIds'] as List? ?? [])
              .whereType<String>()
              .toSet(),
          members: (raw['members'] as Map? ?? {}).map(
            (key, value) => MapEntry('$key', '$value'),
          ),
        ),
      );
    }
  }

  Future<void> save() async {
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode({
        'migrated': _migrated,
        'migrationVersion': _migrated ? 3 : 0,
        'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
      }),
      flush: true,
    );
    temp.renameSync(file.path);
  }

  Future<void> register(Iterable<String> urls) async {
    for (final raw in urls) {
      final url = raw.trim();
      if (!_validUrl(url)) throw const FormatException('订阅地址须为完整 HTTP(S) 地址');
      final existing = subscriptions
          .where((record) => record.url == url)
          .firstOrNull;
      if (existing == null) {
        subscriptions.add(SavedSourceSubscription(url));
      } else {
        existing.excludedIds.clear();
        existing.checkedAt = null;
      }
    }
    await save();
  }

  static bool _validUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty;
  }

  Future<void> _migrate() async {
    if (_migrated) return;
    const prefix =
        'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/';
    // Saved roots already define ownership. Recover script URLs only when no roots exist.
    for (final source
        in subscriptions.isEmpty
            ? await manager.list()
            : const <SourceDescriptor>[]) {
      // 旧版本只保存脚本地址，官方清单可确定恢复；自定义清单需要首次保存根地址。
      if (!source.subscribed || !_validUrl(source.originUrl)) continue;
      final url = source.originUrl.startsWith('$prefix${section.id}/')
          ? '$prefix${section.id}/sources.txt'
          : source.originUrl;
      var record = subscriptions.where((s) => s.url == url).firstOrNull;
      if (record == null) {
        record = SavedSourceSubscription(url);
        subscriptions.add(record);
      }
      record.members[source.id] = source.originUrl;
    }
    // Upgrade once: fetch revised source scripts without waiting out the old interval.
    for (final record in subscriptions) {
      record.checkedAt = null;
    }
    _migrated = true;
    await save();
  }

  Future<SubscriptionSyncResult> sync({bool force = false}) async {
    final result = SubscriptionSyncResult();
    if (!manager.runtimeAvailable) return result;
    await _migrate();
    final http = LumeHttp(source: '${section.label}订阅自动同步');
    try {
      for (final record in subscriptions.where((s) => s.enabled)) {
        final interval = record.error.isEmpty
            ? const Duration(hours: 6)
            : const Duration(minutes: 30);
        if (!force &&
            record.checkedAt != null &&
            _clock().difference(record.checkedAt!) < interval) {
          continue;
        }
        record.checkedAt = _clock();
        try {
          final resolver = SourceSubscription(
            maxScripts: 200,
            strictManifest: true,
            fetch:
                fetch ??
                (url) async {
                  final response = await http.send(url: url);
                  if (response.statusCode < 200 || response.statusCode >= 300) {
                    throw StateError('HTTP ${response.statusCode}');
                  }
                  return SourceFetchResult(
                    bytes: response.body,
                    text: response.text,
                  );
                },
          );
          final refs = await resolver.resolveRefs([record.url]);
          final before = {for (final s in await manager.list()) s.id: s};
          final next = <String, String>{
            for (final entry in record.members.entries)
              if (record.excludedIds.contains(entry.key))
                entry.key: entry.value,
          };
          var complete = resolver.complete;
          for (final ref in refs) {
            final declaredId = SourceMetadata.parseHeader(ref.script)?.id;
            if (record.excludedIds.contains(declaredId) ||
                record.members.entries.any(
                  (entry) =>
                      record.excludedIds.contains(entry.key) &&
                      entry.value == ref.url,
                )) {
              continue;
            }
            final old = before.values
                .where((s) => s.originUrl == ref.url)
                .firstOrNull;
            if (old != null &&
                await manager.exportScript(old.id) == ref.script) {
              next[old.id] = ref.url;
              continue;
            }
            final imported = manager is SubscriptionImportManager
                ? await (manager as SubscriptionImportManager)
                      .importSubscription(ref.script, originUrl: ref.url)
                : await manager.importScript(ref.script, originUrl: ref.url);
            final descriptor = imported.descriptor;
            if (descriptor == null) {
              complete = false;
              result.errors.add('${ref.url}: ${imported.message}');
              continue;
            }
            next[descriptor.id] = ref.url;
            if (before.containsKey(descriptor.id)) {
              result.updated++;
            } else {
              result.added++;
            }
          }
          if (complete) {
            for (final old in record.members.entries) {
              if (next.containsKey(old.key)) continue;
              if (subscriptions.any(
                (s) => s != record && s.members.containsKey(old.key),
              )) {
                continue;
              }
              final existing = before[old.key];
              if (existing == null || existing.originUrl != old.value) continue;
              await manager.remove(old.key);
              result.removed++;
            }
            record.members = next;
            record.error = '';
          } else {
            record.members = {...record.members, ...next};
            record.error = '清单未完整同步，已保留旧源';
            result.errors.add('${record.url}: ${record.error}');
          }
        } catch (error) {
          record.error = '$error';
          result.errors.add('${record.url}: $error');
        }
        await save();
      }
    } finally {
      http.dispose();
    }
    if (result.changed) {
      revision(section).value++;
      changeCount(section).value +=
          result.added + result.updated + result.removed;
    }
    if (result.changed || result.errors.isNotEmpty) {
      LumeLog.info('[订阅] ${section.label}: ${result.summary}');
    }
    return result;
  }

  static Future<SubscriptionSyncResult> refresh(
    Section section, {
    bool force = false,
    SourceManager? manager,
    Future<SourceFetchResult> Function(String url)? fetch,
  }) {
    // 桌面版是 UI 骨架，测试的运行时覆盖不应启动真实后台 IO。
    if (!Platform.isIOS &&
        !Platform.isAndroid &&
        (manager == null || fetch == null)) {
      return Future.value(SubscriptionSyncResult());
    }
    SectionScope.registerShutdownHook('subscription-sync', () async {
      await Future.wait(_running.values.toList());
      for (final section in Section.values) {
        LumeSources.manager(section).close();
      }
    });
    return _running.putIfAbsent(
      section,
      () => _refresh(section, force, manager, fetch),
    );
  }

  static Future<SubscriptionSyncResult> _refresh(
    Section section,
    bool force,
    SourceManager? manager,
    Future<SourceFetchResult> Function(String url)? fetch,
  ) async {
    try {
      final service = await open(section, manager: manager);
      if (fetch == null) return await service.sync(force: force);
      final injected = SourceSubscriptionSync(
        section: section,
        manager: service.manager,
        file: service.file,
        fetch: fetch,
      );
      await injected.load();
      return await injected.sync(force: force);
    } catch (error) {
      final result = SubscriptionSyncResult();
      result.errors.add('$error');
      LumeLog.warn('[订阅] ${section.label}自动同步失败: $error');
      return result;
    } finally {
      _running.remove(section);
    }
  }

  static Future<void> remember(
    Section section,
    Iterable<String> urls, {
    SourceManager? manager,
  }) async {
    await _running[section];
    await (await open(section, manager: manager)).register(urls);
  }

  /// Serializes destructive source maintenance with automatic subscription sync.
  static Future<T> maintenance<T>(
    Section section,
    Future<T> Function() action,
  ) async {
    while (_running[section] != null) {
      await _running[section];
    }
    final completion = Completer<SubscriptionSyncResult>();
    _running[section] = completion.future;
    try {
      return await action();
    } finally {
      completion.complete(SubscriptionSyncResult());
      if (identical(_running[section], completion.future)) {
        _running.remove(section);
      }
      revision(section).value++;
    }
  }

  Future<void> markRemoved(Iterable<SourceDescriptor> removed) async {
    for (final source in removed) {
      for (final record in subscriptions) {
        if (record.members.containsKey(source.id) ||
            record.url == source.originUrl) {
          record.members[source.id] = source.originUrl;
          record.excludedIds.add(source.id);
        }
      }
    }
    await save();
  }

  Future<void> clearSavedSubscriptions() async {
    subscriptions.clear();
    _migrated = true;
    await save();
  }

  static Future<void> waitForIdle(Section section) async {
    await _running[section];
  }
}
