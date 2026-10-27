import 'dart:io';

import '../../core/net/ios_verified_webview.dart';
import '../../core/player/abstract_player.dart';
import '../../core/player/player_experience_store.dart';
import '../../core/player/player_kernel_launcher.dart';
import '../../core/player/player_settings.dart';
import 'playback_preference_wiring.dart';

/// Entry preflight uses the same UA and verified resource cookies as playback.
Future<void> preparePlaybackEntry(
  PlayerPrelaunch prelaunch,
  PlayerMedia media,
  PlayerSettings? settings,
) async {
  final request = PlaybackPreferenceWiring.applyUserAgent(
    media,
    PlayerExperienceStore.current,
  );
  final headers = Platform.isIOS
      ? await IosVerifiedWebView.resourceHeaders(
          media.uri.toString(),
          request.headers ?? const {},
        )
      : request.headers;
  await prelaunch.prepareMedia(
    media,
    settings: settings,
    requestMedia: PlayerMedia(
      uri: media.uri,
      title: media.title,
      headers: headers,
    ),
  );
}
