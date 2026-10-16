import 'glass_modules.dart';
export 'glass_modules.dart';
import 'glass_area.dart';
export 'glass_area.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

/// Additive effects only. Never reads or writes floating_modules.json.
class GlassEffectsSettings extends ChangeNotifier {
  GlassEffectsSettings();
  static final instance = GlassEffectsSettings();
  static const fileName = 'glass_effects_settings.json';

  bool get liquidEnabled => _liquidEnabled;
  bool get playerFrostedEnabled => _playerFrostedEnabled;
  bool _liquidEnabled = false;
  bool _playerFrostedEnabled = true;
  final Map<GlassArea, GlassTuning> _areas = {};
  GlassTuning tuning(GlassArea area) =>
      _areas[area] ??
      (area == GlassArea.fullPlayerPopup
          ? const GlassTuning(enabled: true)
          : area.liquid
          ? const GlassTuning(blur: 8, opacity: .12)
          : const GlassTuning());
  bool active(GlassArea area) =>
      (area.liquid ? liquidEnabled : playerFrostedEnabled && frostedEnabled) &&
      tuning(area).enabled;
  Future<void> setArea(GlassArea area, GlassTuning value) {
    _areas[area] = GlassTuning.fromJson(value.toJson(), fallback: tuning(area));
    notifyListeners();
    return _save();
  }

  bool _frostedEnabled = true;
  bool get frostedEnabled => _frostedEnabled;
  final Map<String, GlassTuning> _modules = {};
  final Map<String, bool> _moduleEnabled = {};
  bool moduleEnabled(GlassModule module) =>
      _moduleEnabled[module.name] != false;
  Future<void> setModuleEnabled(GlassModule module, bool enabled) {
    _moduleEnabled[module.name] = enabled;
    notifyListeners();
    return _save();
  }

  GlassTuning moduleTuning(GlassModule module, GlassPart part) {
    final value =
        _modules['${module.name}.${part.name}'] ??
        _modules['all.${part.name}'] ??
        const GlassTuning();
    if (!moduleEnabled(module) || !moduleEnabled(GlassModule.all)) {
      return value.copyWith(enabled: false);
    }
    return part.allowsLiquid ? value : value.copyWith(liquid: false);
  }

  bool hasModuleConfiguration(GlassModule module, GlassPart part) =>
      !moduleEnabled(module) ||
      !moduleEnabled(GlassModule.all) ||
      _modules.containsKey('${module.name}.${part.name}') ||
      _modules.containsKey('all.${part.name}');
  Future<void> resetModule(GlassModule module, GlassPart part) {
    _modules.remove('${module.name}.${part.name}');
    notifyListeners();
    return _save();
  }

  Future<void> setModule(
    GlassModule module,
    GlassPart part,
    GlassTuning value,
  ) {
    _modules['${module.name}.${part.name}'] = GlassTuning.fromJson(
      value.toJson(),
      fallback: const GlassTuning(),
    );
    notifyListeners();
    return _save();
  }

  Future<void> setFrostedEnabled(bool value) {
    _frostedEnabled = value;
    notifyListeners();
    return _save();
  }

  File? _file;
  Future<void> _pending = Future<void>.value();

  Future<void> boot({Directory? directory}) async {
    await _pending;
    _liquidEnabled = false;
    _playerFrostedEnabled = true;
    _areas.clear();
    _modules.clear();
    _moduleEnabled.clear();
    _frostedEnabled = true;
    try {
      final base = directory ?? await getApplicationSupportDirectory();
      _file = File('${base.path}/$fileName');
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        if (data is Map) {
          _liquidEnabled = data['liquidEnabled'] == true;
          _frostedEnabled = data['frostedEnabled'] != false;
          final enabled = data['moduleEnabled'];
          if (enabled is Map) {
            for (final module in GlassModule.values) {
              if (enabled[module.name] is bool) {
                _moduleEnabled[module.name] = enabled[module.name] as bool;
              }
            }
          }
          final modules = data['modules'];
          if (modules is Map) {
            for (final entry in modules.entries) {
              _modules['${entry.key}'] = GlassTuning.fromJson(
                entry.value,
                fallback: const GlassTuning(),
              );
            }
          }
          final areas = data['areas'];
          if (areas is Map) {
            for (final area in GlassArea.values) {
              _areas[area] = GlassTuning.fromJson(
                areas[area.name],
                fallback: tuning(area),
              );
            }
          }
          _playerFrostedEnabled = data['playerFrostedEnabled'] is bool
              ? data['playerFrostedEnabled'] as bool
              : true;
        }
      }
    } catch (error) {
      LumeLog.warn('玻璃效果配置读取失败：$error');
    }
    notifyListeners();
  }

  Future<void> setLiquidEnabled(bool value) {
    _liquidEnabled = value;
    notifyListeners();
    return _save();
  }

  Future<void> setPlayerFrostedEnabled(bool value) {
    _playerFrostedEnabled = value;
    notifyListeners();
    return _save();
  }

  Future<void> _save() {
    final contents = jsonEncode({
      'liquidEnabled': _liquidEnabled,
      'frostedEnabled': _frostedEnabled,
      'moduleEnabled': _moduleEnabled,
      'modules': {
        for (final entry in _modules.entries) entry.key: entry.value.toJson(),
      },
      'playerFrostedEnabled': _playerFrostedEnabled,
      'areas': {
        for (final area in GlassArea.values) area.name: tuning(area).toJson(),
      },
    });
    _pending = _pending.then((_) async {
      try {
        if (_file == null) {
          final base = await getApplicationSupportDirectory();
          _file = File('${base.path}/$fileName');
        }
        final file = _file!;
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(contents, flush: true);
        await temporary.rename(file.path);
      } catch (error) {
        LumeLog.warn('玻璃效果配置保存失败：$error');
      }
    });
    return _pending;
  }
}
