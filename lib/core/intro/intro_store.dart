import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'intro_models.dart';

/// A private database: reference player never overwrites original skip marks.
class IntroStore extends ValueNotifier<IntroOptions> {
  IntroStore(this.db) : super(IntroOptions()) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS preferences (id TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS segments (episode TEXT PRIMARY KEY, season TEXT NOT NULL, duration INTEGER NOT NULL, manual INTEGER NOT NULL, value TEXT NOT NULL, updated INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS fingerprints (episode TEXT PRIMARY KEY, season TEXT NOT NULL, duration INTEGER NOT NULL, value TEXT NOT NULL, updated INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS recognition_log (id INTEGER PRIMARY KEY, value TEXT NOT NULL)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS segment_season ON segments (season, manual, updated)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS fingerprint_season ON fingerprints (season, updated)',
    );
    final rows = db.select("SELECT value FROM preferences WHERE id='options'");
    if (rows.isNotEmpty) {
      try {
        value = IntroOptions(
          Map<String, Object?>.from(
            jsonDecode(rows.first['value'] as String) as Map,
          ),
        );
      } catch (_) {
        /* use defaults on damaged preferences */
      }
    }
  }
  final Database db;
  static Future<IntroStore>? _opening;
  static Future<IntroStore> open() => _opening ??= _open();
  static Future<IntroStore> _open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return IntroStore(
        sqlite3.open(path.join(dir.path, 'reference_intro.sqlite')),
      );
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  void update(Map<String, Object?> changes) {
    final next = value.patch(changes);
    db.execute("INSERT OR REPLACE INTO preferences VALUES ('options', ?)", [
      jsonEncode(next.values),
    ]);
    value = next;
  }

  List<SkipSegment> readSegments(
    EpisodeIdentity episode,
    int duration, {
    bool manual = false,
    bool reuseSeason = false,
  }) {
    var rows = db.select(
      'SELECT * FROM segments WHERE episode=? AND manual=?',
      [manual ? 'manual:${episode.key}' : episode.key, manual ? 1 : 0],
    );
    if (rows.isEmpty && manual && reuseSeason) {
      rows = db.select(
        "SELECT * FROM segments WHERE season=? AND manual=1 AND value<>'[]' AND ABS(duration-?)<=2000 ORDER BY updated DESC LIMIT 1",
        [episode.seasonKey, duration],
      );
    }
    if (rows.isEmpty) return [];
    final row = rows.first;
    if (!manual) {
      final config = db.select('SELECT value FROM preferences WHERE id=?', [
        'detector-config:${episode.key}',
      ]);
      if (config.isEmpty || config.first['value'] != jsonEncode(value.values)) {
        return [];
      }
      final identity = db.select('SELECT value FROM preferences WHERE id=?', [
        'detector-identity:${episode.key}',
      ]);
      if (identity.isEmpty ||
          identity.first['value'] != _identitySignature(episode)) {
        return [];
      }
      if (DateTime.now().millisecondsSinceEpoch - (row['updated'] as int) >
          const Duration(days: 7).inMilliseconds) {
        return [];
      }
    }
    // Different edits are never blindly shifted to match runtime.
    if (((row['duration'] as int) - duration).abs() > 2000) return [];
    try {
      return (jsonDecode(row['value'] as String) as List)
          .map(SkipSegment.parse)
          .whereType<SkipSegment>()
          .where((s) => s.validFor(duration))
          .toList();
    } catch (_) {
      return [];
    }
  }

  void saveSegments(
    EpisodeIdentity episode,
    int duration,
    List<SkipSegment> segments, {
    bool manual = false,
  }) {
    if (segments.any((s) => !s.validFor(duration))) {
      throw ArgumentError('Invalid segment bounds');
    }
    // Manual and machine results have separate keys, including an empty manual set.
    final key = manual ? 'manual:${episode.key}' : episode.key;
    db.execute('INSERT OR REPLACE INTO segments VALUES (?, ?, ?, ?, ?, ?)', [
      key,
      episode.seasonKey,
      duration,
      manual ? 1 : 0,
      jsonEncode(segments.map((s) => s.toJson()).toList()),
      DateTime.now().millisecondsSinceEpoch,
    ]);
    if (!manual) {
      db.execute('INSERT OR REPLACE INTO preferences VALUES (?, ?)', [
        'detector-config:${episode.key}',
        jsonEncode(value.values),
      ]);
      db.execute('INSERT OR REPLACE INTO preferences VALUES (?, ?)', [
        'detector-identity:${episode.key}',
        _identitySignature(episode),
      ]);
    }
  }

  List<SkipSegment> manual(
    EpisodeIdentity episode,
    int duration, {
    bool reuseSeason = false,
  }) {
    var rows = db.select(
      'SELECT * FROM segments WHERE episode=? AND manual=1',
      ['manual:${episode.key}'],
    );
    if (rows.isEmpty && reuseSeason) {
      rows = db.select(
        "SELECT * FROM segments WHERE season=? AND manual=1 AND value<>'[]' AND ABS(duration-?)<=2000 ORDER BY updated DESC LIMIT 1",
        [episode.seasonKey, duration],
      );
    }
    if (rows.isEmpty ||
        ((rows.first['duration'] as int) - duration).abs() > 2000) {
      return [];
    }
    return (jsonDecode(rows.first['value'] as String) as List)
        .map(SkipSegment.parse)
        .whereType<SkipSegment>()
        .where((s) => s.validFor(duration))
        .toList();
  }

  void clearManual(EpisodeIdentity episode) => db.execute(
    'DELETE FROM segments WHERE episode=?',
    ['manual:${episode.key}'],
  );
  void saveFingerprint(
    EpisodeIdentity episode,
    int duration,
    Map<String, Object?> data,
  ) {
    db.execute('INSERT OR REPLACE INTO fingerprints VALUES (?, ?, ?, ?, ?)', [
      episode.key,
      episode.seasonKey,
      duration,
      jsonEncode(data),
      DateTime.now().millisecondsSinceEpoch,
    ]);
    db.execute(
      'DELETE FROM fingerprints WHERE episode IN (SELECT episode FROM fingerprints ORDER BY updated DESC LIMIT -1 OFFSET 300)',
    );
  }

  List<Map<String, Object?>> fingerprints(EpisodeIdentity episode) => db
      .select(
        'SELECT * FROM fingerprints WHERE season=? AND episode<>? ORDER BY updated DESC LIMIT 12',
        [episode.seasonKey, episode.key],
      )
      .map(
        (row) => Map<String, Object?>.from(
          jsonDecode(row['value'] as String) as Map,
        ),
      )
      .toList();
  void record(RecognitionRecord record) {
    if (!value.logs) return;
    db.execute('INSERT INTO recognition_log(value) VALUES (?)', [
      jsonEncode(record.toJson()),
    ]);
    db.execute(
      'DELETE FROM recognition_log WHERE id NOT IN (SELECT id FROM recognition_log ORDER BY id DESC LIMIT 2000)',
    );
  }

  List<Map<String, Object?>> recentLogs() => db
      .select('SELECT value FROM recognition_log ORDER BY id DESC LIMIT 200')
      .map(
        (r) =>
            Map<String, Object?>.from(jsonDecode(r['value'] as String) as Map),
      )
      .toList();
  void clearLogs() => db.execute('DELETE FROM recognition_log');
  Map<String, Object?> identity(String series) {
    final rows = db.select('SELECT value FROM preferences WHERE id=?', [
      'identity:$series',
    ]);
    if (rows.isEmpty) return {};
    try {
      return Map<String, Object?>.from(
        jsonDecode(rows.first['value'] as String) as Map,
      );
    } catch (_) {
      return {};
    }
  }

  void saveIdentity(String series, Map<String, Object?> data) => db.execute(
    'INSERT OR REPLACE INTO preferences VALUES (?, ?)',
    ['identity:$series', jsonEncode(data)],
  );

  static String _identitySignature(EpisodeIdentity episode) =>
      jsonEncode([episode.tmdb, episode.imdb]);
}
