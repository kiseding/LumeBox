import '../util/sensitive_data.dart';

/// Bounded metadata only: never store playback paths, query strings or headers.
abstract final class PlaybackDiagnostics {
  static final List<Map<String, Object?>> _events = [];
  static List<Map<String, Object?>> get snapshot => [
    for (final e in _events) Map.unmodifiable(e),
  ];
  static void record(
    String stage, {
    String? source,
    String? kernel,
    Uri? uri,
    int? elapsedMs,
    String? error,
  }) {
    _events.add({
      'time': DateTime.now().toIso8601String(),
      'stage': stage,
      'source': ?source,
      'kernel': ?kernel,
      if (uri != null) 'host': uri.host,
      'elapsedMs': ?elapsedMs,
      if (error != null)
        'error': SensitiveData.redact(error)
            .replaceAll(RegExp(r'https?://[^\s]+'), '[URL omitted]'),
    });
    if (_events.length > 30) _events.removeAt(0);
  }
}
