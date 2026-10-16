enum GlassArea {
  fullPlayerPopup('完整播放器弹窗（预留）', false),
  videoSettings('视频播放器设置弹窗', false),
  primaryControls('播放 / 暂停 / 快进等主控小按钮', true),
  utilityControls('画中画 / 全屏 / 设置等辅助小按钮', true),
  subscriptionBadges('订阅图标的数字徽标', true);

  const GlassArea(this.label, this.liquid);
  final String label;
  final bool liquid;
}

class GlassTuning {
  const GlassTuning({
    this.enabled = false,
    this.liquid = false,
    this.blur = 18,
    this.opacity = .72,
    this.radius = 20,
    this.border = true,
    this.highlight = .5,
    this.distort = .3,
    this.speed = 1,
  });
  final bool enabled, border, liquid;
  final double blur, opacity, radius, highlight, distort, speed;
  GlassTuning copyWith({
    bool? enabled,
    bool? liquid,
    double? blur,
    double? opacity,
    double? radius,
    bool? border,
    double? highlight,
    double? distort,
    double? speed,
  }) => GlassTuning(
    enabled: enabled ?? this.enabled,
    liquid: liquid ?? this.liquid,
    blur: blur ?? this.blur,
    opacity: opacity ?? this.opacity,
    radius: radius ?? this.radius,
    border: border ?? this.border,
    highlight: highlight ?? this.highlight,
    distort: distort ?? this.distort,
    speed: speed ?? this.speed,
  );
  Map<String, Object> toJson() => {
    'enabled': enabled,
    'liquid': liquid,
    'blur': blur,
    'opacity': opacity,
    'radius': radius,
    'border': border,
    'highlight': highlight,
    'distort': distort,
    'speed': speed,
  };
  factory GlassTuning.fromJson(Object? raw, {required GlassTuning fallback}) {
    if (raw is! Map) return fallback;
    double number(String key, double old, double max) {
      final value = raw[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(0, max)
          : old;
    }

    return GlassTuning(
      liquid: raw['liquid'] is bool ? raw['liquid'] as bool : fallback.liquid,
      enabled: raw['enabled'] is bool
          ? raw['enabled'] as bool
          : fallback.enabled,
      blur: number('blur', fallback.blur, 40),
      opacity: number('opacity', fallback.opacity, 1),
      radius: number('radius', fallback.radius, 40),
      border: raw['border'] is bool ? raw['border'] as bool : fallback.border,
      highlight: number('highlight', fallback.highlight, 1),
      distort: number('distort', fallback.distort, 1),
      speed: number('speed', fallback.speed, 2).clamp(.25, 2),
    );
  }
}
