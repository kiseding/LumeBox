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
  File? _file;
  Future<void> _pending = Future<void>.value();

  Future<void> boot({Directory? directory}) async {
    await _pending;
    _liquidEnabled = false;
    _playerFrostedEnabled = true;
    try {
      final base = directory ?? await getApplicationSupportDirectory();
      _file = File('${base.path}/$fileName');
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        if (data is Map) {
          _liquidEnabled = data['liquidEnabled'] == true;
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
      'playerFrostedEnabled': _playerFrostedEnabled,
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
