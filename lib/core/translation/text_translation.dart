import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef TextTranslator = Future<List<String>> Function(List<String> texts);

/// Display-only translations. IDs, original metadata and search queries stay intact.
class TextTranslationService extends ChangeNotifier {
  TextTranslationService({this.file, this.translator});
  static final shared = TextTranslationService();
  final File? file;
  final TextTranslator? translator;
  final Map<String, String> _cache = {};
  Future<void>? _boot;
  Future<void> _writes = Future.value();
  int _revision = 0;
  static Future<void> _nativeQueue = Future.value();
  static int _sequence = 0;
  static const channel = MethodChannel('lumebox/comicImages');
  static const maxEntries = 2000;
  bool displayOriginal = false;
  void toggleOriginal() {
    displayOriginal = !displayOriginal;
    notifyListeners();
  }

  String _key(String text, String source, String target) => sha256
      .convert(utf8.encode(jsonEncode([1, source, target, text])))
      .toString();
  String? lookup(
    String text, {
    String source = 'auto',
    String target = 'zh-Hans',
  }) => _cache[_key(text, source, target)];
  Future<File> _file() async =>
      file ??
      File(
        '${(await getApplicationSupportDirectory()).path}/text_translations.json',
      );

  Future<void> boot() => _boot ??= () async {
    try {
      final store = await _file();
      if (await store.exists() && await store.length() <= 12 * 1024 * 1024) {
        final data = jsonDecode(await store.readAsString());
        if (data is Map) {
          for (final entry in data.entries.take(maxEntries)) {
            if (entry.key is String &&
                RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key) &&
                entry.value is String &&
                (entry.value as String).length <= 100000) {
              _cache.putIfAbsent(entry.key, () => entry.value as String);
            }
          }
        }
      }
    } catch (_) {
      /* Cache failure must not block browsing or reading. */
    }
    notifyListeners();
  }();

  Future<List<String>> translate(
    List<String> texts, {
    String source = 'auto',
    String target = 'zh-Hans',
    TextTranslator? using,
  }) async {
    await boot();
    final revision = _revision;
    if (texts.any((t) => t.runes.length > 40000) ||
        texts.fold<int>(0, (n, t) => n + t.runes.length) > 40000 ||
        texts.length > 100) {
      throw const FormatException('翻译文字过长，请分段处理');
    }
    final missing = texts
        .where(
          (t) =>
              t.trim().isNotEmpty &&
              lookup(t, source: source, target: target) == null,
        )
        .toSet()
        .toList();
    if (missing.isNotEmpty) {
      final result = Completer<List<String>>();
      // Apple's presentation owns one session. Serialize callers, then recheck
      // the cache so overlapping requests cannot open competing system sheets.
      _nativeQueue = _nativeQueue.catchError((Object _) {}).then((_) async {
        try {
          if (revision != _revision) throw StateError('译文缓存已清理，请重试');
          final pending = missing
              .where((t) => lookup(t, source: source, target: target) == null)
              .toList();
          if (pending.isNotEmpty) {
            PlatformException? partial;
            late final List<String> values;
            try {
              values = await (using ??
                    translator ??
                    (values) => _native(values, source, target))(pending);
            } on PlatformException catch (error) {
              final details = error.details;
              if (error.code != 'translation_partial' ||
                  details is! List ||
                  details.length != pending.length ||
                  details.any((v) => v is! String || v.length > 100000)) {
                rethrow;
              }
              values = details.cast<String>();
              partial = error;
            }
            if (revision != _revision) throw StateError('译文缓存已清理，请重试');
            if (values.length != pending.length ||
                values.any((v) =>
                    (partial == null && v.trim().isEmpty) || v.length > 100000)) {
              throw const FormatException('翻译结果不完整，请重试');
            }
            for (var i = 0; i < pending.length; i++) {
              if (values[i].trim().isEmpty) continue;
              final key = _key(pending[i], source, target);
              _cache.remove(key);
              _cache[key] = values[i];
            }
            while (_cache.length > maxEntries) {
              _cache.remove(_cache.keys.first);
            }
            notifyListeners();
            unawaited(_save());
            if (partial != null) throw partial;
          }
          result.complete(
            texts
                .map((t) => lookup(t, source: source, target: target) ?? t)
                .toList(),
          );
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      });
      return result.future;
    }
    return texts
        .map((t) => lookup(t, source: source, target: target) ?? t)
        .toList();
  }

  Future<List<String>> _native(
    List<String> texts,
    String source,
    String target,
  ) async {
    final id = 'metadata-${_sequence++}';
    try {
      final values = await channel
          .invokeListMethod<String>('translate', {
            'id': id,
            'texts': texts,
            'source': source,
            'target': target,
          })
          .timeout(const Duration(minutes: 3));
      if (values == null) throw const FormatException('未返回译文');
      return values;
    } on TimeoutException {
      unawaited(
        channel
            .invokeMethod<void>('cancel', {'id': id})
            .catchError((Object _) {}),
      );
      rethrow;
    }
  }

  Future<void> _save() {
    var data = jsonEncode(_cache);
    while (utf8.encode(data).length > 10 * 1024 * 1024 && _cache.isNotEmpty) {
      _cache.remove(_cache.keys.first);
      data = jsonEncode(_cache);
    }
    final snapshot = data;
    _writes = _writes.catchError((Object _) {}).then((_) async {
      try {
        final store = await _file();
        await store.parent.create(recursive: true);
        final temporary = File('${store.path}.tmp');
        await temporary.writeAsString(snapshot, flush: true);
        await temporary.rename(store.path);
      } catch (_) {
        /* The in-memory translation remains usable. */
      }
    });
    return _writes;
  }

  Future<void> flush() => _writes;
  Future<void> clear() async {
    await boot();
    _revision++;
    _cache.clear();
    displayOriginal = false;
    notifyListeners();
    await _save();
  }
}
