import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class AppPreferences {
  static final instance = AppPreferences();
  bool haptics = false, backgroundPlayback = true, autoBackup = false;
  File? file;
  Future<void> boot() async {
    file = File(
      '${(await getApplicationSupportDirectory()).path}/app_preferences.json',
    );
    if (!file!.existsSync()) return;
    try {
      final data = jsonDecode(file!.readAsStringSync()) as Map;
      haptics = data['haptics'] == true;
      backgroundPlayback = data['backgroundPlayback'] != false;
      autoBackup = data['autoBackup'] == true;
    } catch (_) {
      /* Keep defaults for invalid local settings. */
    }
  }

  void save() {
    final target = file;
    if (target == null) return;
    target.parent.createSync(recursive: true);
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode({
        'haptics': haptics,
        'backgroundPlayback': backgroundPlayback,
        'autoBackup': autoBackup,
      }),
      flush: true,
    );
    temp.renameSync(target.path);
  }

  void selectionFeedback() {
    if (haptics) HapticFeedback.selectionClick();
  }
}
