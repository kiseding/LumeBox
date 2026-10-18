import 'dart:convert';

/// Preferences shown by the reference video's playback settings. Existing
/// per-kernel speed/subtitle preferences remain in PlayerSettings.
class PlayerExperience {
  const PlayerExperience._(this.values);
  const PlayerExperience() : values = const {};
  final Map<String, Object?> values;

  bool flag(String key, [bool fallback = false]) =>
      values[key] is bool ? values[key] as bool : fallback;
  String text(String key, [String fallback = '']) =>
      values[key] is String ? values[key] as String : fallback;
  double number(String key, double fallback, double min, double max) {
    final value = values[key];
    return value is num && value.isFinite
        ? value.toDouble().clamp(min, max)
        : fallback;
  }

  bool get autoKernelSwitch => flag('autoKernelSwitch', true);
  bool get backgroundPlayback => flag('backgroundPlayback', true);
  bool get swapGestureSides => flag('swapGestureSides');
  bool get swipeEpisodes => flag('swipeEpisodes');
  bool get twoFingerEpisodes => flag('twoFingerEpisodes');
  bool get followSystemBrightness => flag('followSystemBrightness', true);
  bool get rememberBrightness => flag('rememberBrightness', true);
  bool get selectEpisodeOnly => flag('selectEpisodeOnly');
  bool get shortDramaPreload => flag('shortDramaPreload');
  int get preloadMinutes => number('preloadMinutes', 5, 1, 10).round();
  String get browserUA => text('browserUA').trim();
  String get subtitleLanguage =>
      const [
        'source',
        'zh-Hans',
        'zh-Hant',
        'yue',
        'en',
        'ja',
        'ko',
        'off',
      ].contains(text('subtitleLanguage'))
      ? text('subtitleLanguage')
      : 'source';
  int get mpvBufferMB => number('mpvBufferMB', 150, 50, 1000).round();
  int get mpvBufferSeconds => number('mpvBufferSeconds', 120, 10, 1000).round();
  int get mdkBufferSeconds => number('mdkBufferSeconds', 30, 10, 1000).round();
  String get mpvRenderer =>
      text('mpvRenderer') == 'gpu-next' ? 'gpu-next' : 'gpu';
  String get mpvConf => text('mpvConf');
  bool logging(String kernel) => flag('$kernel.logging');
  PlayerButtonLayout get layout =>
      PlayerButtonLayout.fromJson(values['layout']);

  PlayerExperience update(Map<String, Object?> patch) =>
      PlayerExperience._(Map.unmodifiable({...values, ...patch}));
  Map<String, Object?> toJson() => Map.of(values);
  factory PlayerExperience.fromJson(Object? raw) => raw is Map
      ? PlayerExperience._(
          Map.unmodifiable({
            for (final entry in raw.entries)
              if (entry.key is String) entry.key as String: entry.value,
          }),
        )
      : const PlayerExperience();
  static PlayerExperience decode(String? raw) {
    try {
      return PlayerExperience.fromJson(jsonDecode(raw ?? '{}'));
    } catch (_) {
      return const PlayerExperience();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerExperience &&
      jsonEncode(other.values) == jsonEncode(values);
  @override
  int get hashCode => jsonEncode(values).hashCode;
}

class PlayerButtonLayout {
  const PlayerButtonLayout({
    this.top = defaultTop,
    this.bottom = defaultBottom,
    this.hidden = const [],
  });
  static const defaultTop = [
    'kernel',
    'decode',
    'intro',
    'skip',
    'outro',
    'pip',
    'fullscreen',
    'comment',
  ];
  static const defaultBottom = [
    'speed',
    'subtitle',
    'audio',
    'danmaku',
    'quality',
    'ratio',
    'picture',
    'info',
    'episodes',
    'cast',
    'airplay',
  ];
  static const labels = {
    'kernel': '内核',
    'decode': '硬解 / 软解',
    'intro': '片头',
    'skip': '跳过片头片尾',
    'outro': '片尾',
    'pip': '小窗',
    'fullscreen': '全屏',
    'speed': '倍速',
    'subtitle': '字幕',
    'audio': '音轨',
    'danmaku': '弹幕',
    'quality': '画质',
    'ratio': '比例',
    'picture': '画面',
    'info': '信息',
    'episodes': '选集',
    'comment': '评论',
    'cast': '投屏',
    'airplay': 'AirPlay（iOS）',
  };
  final List<String> top, bottom, hidden;

  factory PlayerButtonLayout.fromJson(Object? raw) {
    if (raw is! Map) return const PlayerButtonLayout();
    final seen = <String>{};
    List<String> group(String name) {
      final list = raw[name];
      if (list is! List) return [];
      return [
        for (final id in list)
          if (id is String && labels.containsKey(id) && seen.add(id)) id,
      ];
    }

    final top = group('top'),
        bottom = group('bottom'),
        hidden = group('hidden');
    // New controls introduced by a later version remain reachable.
    hidden.addAll(labels.keys.where((id) => !seen.contains(id)));
    return PlayerButtonLayout(
      top: List.unmodifiable(top),
      bottom: List.unmodifiable(bottom),
      hidden: List.unmodifiable(hidden),
    );
  }
  Map<String, Object> toJson() => {
    'top': top,
    'bottom': bottom,
    'hidden': hidden,
  };
}

/// mpv.conf option parsing: preserves spaces in values and reports malformed
/// lines. Profiles/includes need mpv's file loader and aren't silently emulated.
class MpvConfOptions {
  static Map<String, String> parse(String input) {
    final result = <String, String>{};
    for (final (index, raw) in input.split('\n').indexed) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final split = line.indexOf('=');
      if (split < 1 || line.startsWith('[')) {
        throw FormatException('第 ${index + 1} 行需要 key=value');
      }
      final name = line.substring(0, split).trim();
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name)) {
        throw FormatException('第 ${index + 1} 行的选项名称无效');
      }
      if (const [
        'include',
        'script',
        'scripts',
        'input-ipc-server',
      ].contains(name)) {
        throw FormatException('移动端不支持配置选项 $name');
      }
      var value = line.substring(split + 1).trim();
      if (value.length >= 2 &&
          (value.startsWith('"') && value.endsWith('"') ||
              value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      result[name] = value;
    }
    return result;
  }
}
