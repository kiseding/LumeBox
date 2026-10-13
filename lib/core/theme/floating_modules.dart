import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

enum FloatingModule {
  navigation('顶部导航'),
  home('首页功能、分类与筛选'),
  dock('底部导航'),
  overlay('其他悬浮面板');

  const FloatingModule(this.label);
  final String label;
}

class FloatingStyle {
  const FloatingStyle({
    this.opacity = .18,
    this.x = 0,
    this.y = 0,
    this.blur = 12,
  });
  final double opacity, x, y, blur;
  Offset get offset => Offset(x, y);
  FloatingStyle copyWith({
    double? opacity,
    double? x,
    double? y,
    double? blur,
  }) => FloatingStyle(
    opacity: opacity ?? this.opacity,
    x: x ?? this.x,
    y: y ?? this.y,
    blur: blur ?? this.blur,
  );
  Map<String, double> toJson() => {
    'opacity': opacity,
    'x': x,
    'y': y,
    'blur': blur,
  };
  factory FloatingStyle.fromJson(Map value) {
    double read(String key, double fallback, double min, double max) {
      final raw = value[key];
      return raw is num && raw.isFinite
          ? raw.toDouble().clamp(min, max)
          : fallback;
    }

    return FloatingStyle(
      opacity: read('opacity', .18, 0, 1),
      x: read('x', 0, -40, 40),
      y: read('y', 0, -40, 80),
      blur: read('blur', 12, 0, 30),
    );
  }
}

class FloatingModules extends ChangeNotifier {
  FloatingModules._();
  static final instance = FloatingModules._();
  final Map<FloatingModule, FloatingStyle> _styles = {};
  File? _file;
  FloatingStyle style(FloatingModule module) =>
      _styles[module] ?? const FloatingStyle();
  Future<void> boot() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/floating_modules.json');
      if (_file!.existsSync()) {
        final data = jsonDecode(_file!.readAsStringSync());
        if (data is Map) {
          for (final module in FloatingModule.values) {
            final raw = data[module.name];
            if (raw is Map) _styles[module] = FloatingStyle.fromJson(raw);
          }
        }
      }
      notifyListeners();
    } catch (error) {
      LumeLog.warn('悬浮设置读取失败：$error');
    }
  }

  void set(FloatingModule module, FloatingStyle value) {
    _styles[module] = module == FloatingModule.dock
        ? value.copyWith(y: value.y.clamp(-40, 20))
        : value;
    notifyListeners();
  }

  void reset(FloatingModule module) => set(module, const FloatingStyle());
  void save() {
    final file = _file;
    if (file == null) return;
    try {
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(
        jsonEncode({
          for (final e in _styles.entries) e.key.name: e.value.toJson(),
        }),
        flush: true,
      );
      temp.renameSync(file.path);
    } catch (error) {
      LumeLog.warn('悬浮设置保存失败：$error');
    }
  }
}
