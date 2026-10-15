import '../../core/player/player_settings.dart';
import '../../core/source/source.dart';

/// Only chooses an existing address. No requests, retries or adaptive bitrate policy.
class PlaybackQualityPreference {
  static VideoQuality? select(
    List<VideoQuality> qualities,
    PlayerSettings settings,
  ) {
    if (settings.rememberManualQuality &&
        settings.manualQualityLabel.isNotEmpty) {
      for (final quality in qualities) {
        if (quality.label == settings.manualQualityLabel) return quality;
      }
    }
    VideoQuality? best;
    var rank = 0;
    for (final quality in qualities) {
      if (quality.resolutionRank > rank) {
        best = quality;
        rank = quality.resolutionRank;
      }
    }
    return best;
  }
}
