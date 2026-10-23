import 'core/media/media_library.dart';
import 'core/tmdb/tmdb.dart';
import 'core/session/app_preferences.dart';
import 'core/session/configuration_backup.dart';
import 'core/search/search_settings.dart';
import 'core/source/source_content_visibility.dart';
import 'core/theme/floating_modules.dart';
import 'core/theme/frosted_settings.dart';
import 'core/reading/comic_image_tools.dart';
import 'core/session/privacy_settings.dart';
import 'core/session/retired_module_cache.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/js/sandbox_settings.dart';
import 'core/player/playback_orientation.dart';
import 'core/reading/browse_layout.dart';
import 'core/shell/shell_settings.dart';
import 'core/theme/appearance.dart';
import 'core/theme/user_fonts.dart';
import 'core/net/lume_net.dart';
import 'core/util/developer_mode.dart';
import 'core/util/lume_log.dart';

void main() {
  runZonedGuarded<void>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Independent local reads overlap; privacy, networking, appearance and
    // navigation are all ready before any page starts its first request.
    await Future.wait<void>([
      AppPreferences.instance.boot(),
      PrivacySettings.instance.boot(),
      MediaLibrary.instance.boot(),
      LumeNet.boot(),
      LumeSandboxSettings.boot(),
      DeveloperMode.boot(),
      BrowseLayoutSettings.instance.boot(),
      PlaybackOrientationController.instance.boot(),
      ShellSettingsController.instance.boot(),
      SourceContentVisibility.instance.boot(),
      SearchSettings.instance.boot(),
      TmdbSettings.instance.boot(),
      AppearanceController.instance.boot(),
      UserFonts.instance.boot(),
      FloatingModules.instance.boot(),
      FrostedSettings.instance.boot(),
      ComicImageToolsSettings.instance.boot(),
    ]);
    // The selected font depends on both the appearance and font index.
    await UserFonts.instance.ensureLoaded(
      AppearanceController.instance.settings.fontId,
    );
    runApp(const LumeBoxApp());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startupMaintenance());
    });
  }, (error, stackTrace) => LumeLog.error(error, stackTrace));
}

Future<void> _startupMaintenance() async {
  // Leave first-screen source/cover loading time before disk maintenance.
  await Future<void>.delayed(const Duration(seconds: 8));
  await clearRetiredModuleCache();
  if (AppPreferences.instance.autoBackup) {
    try {
      await ConfigurationBackup().automatic();
    } catch (error) {
      LumeLog.warn('自动备份失败：$error');
    }
  }
}
