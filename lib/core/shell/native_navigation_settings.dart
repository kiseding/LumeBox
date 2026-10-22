/// Preferences for the system tab bar, independent of the custom Dock material.
class NativeNavigationSettings {
  const NativeNavigationSettings({
    this.enabled = true,
    this.showLabels = true,
    this.followThemeColor = true,
    this.tintColor = 0xFF7C5CFF,
    this.iconSize = 24,
    this.horizontalMargin = 0,
    this.safeGap = 0,
  });

  final bool enabled;
  final bool showLabels;
  final bool followThemeColor;
  final int tintColor;
  final double iconSize;
  final double horizontalMargin;
  final double safeGap;

  NativeNavigationSettings copyWith({
    bool? enabled,
    bool? showLabels,
    bool? followThemeColor,
    int? tintColor,
    double? iconSize,
    double? horizontalMargin,
    double? safeGap,
  }) => NativeNavigationSettings.fromJson({
    ...toJson(),
    'enabled': ?enabled,
    'showLabels': ?showLabels,
    'followThemeColor': ?followThemeColor,
    'tintColor': ?tintColor,
    'iconSize': ?iconSize,
    'horizontalMargin': ?horizontalMargin,
    'safeGap': ?safeGap,
  });

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'showLabels': showLabels,
    'followThemeColor': followThemeColor,
    'tintColor': tintColor,
    'iconSize': iconSize,
    'horizontalMargin': horizontalMargin,
    'safeGap': safeGap,
  };

  static NativeNavigationSettings fromJson(Object? value) {
    if (value is! Map) return const NativeNavigationSettings();
    double number(String key, double fallback, double min, double max) {
      final raw = value[key];
      return raw is num && raw.isFinite
          ? raw.toDouble().clamp(min, max)
          : fallback;
    }

    final tint = value['tintColor'];
    return NativeNavigationSettings(
      enabled: value['enabled'] is bool ? value['enabled'] as bool : true,
      showLabels: value['showLabels'] is bool
          ? value['showLabels'] as bool
          : true,
      followThemeColor: value['followThemeColor'] is bool
          ? value['followThemeColor'] as bool
          : true,
      tintColor: tint is int && tint >= 0 && tint <= 0xFFFFFFFF
          ? tint | 0xFF000000
          : 0xFF7C5CFF,
      iconSize: number('iconSize', 24, 18, 30),
      horizontalMargin: number('horizontalMargin', 0, 0, 40),
      safeGap: number('safeGap', 0, 0, 32),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NativeNavigationSettings &&
      enabled == other.enabled &&
      showLabels == other.showLabels &&
      followThemeColor == other.followThemeColor &&
      tintColor == other.tintColor &&
      iconSize == other.iconSize &&
      horizontalMargin == other.horizontalMargin &&
      safeGap == other.safeGap;

  @override
  int get hashCode => Object.hash(
    enabled,
    showLabels,
    followThemeColor,
    tintColor,
    iconSize,
    horizontalMargin,
    safeGap,
  );
}
