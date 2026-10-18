import 'dart:io';

import '../util/lume_log.dart';
import 'abstract_player.dart';
import 'av_player.dart';
import 'buffering.dart';
import 'media_kit_mpv_engine.dart';
import 'mpv_engine.dart';
import 'mpv_player.dart';
import 'player_experience_store.dart';
import 'player_factory.dart';
import 'player_settings.dart';
import 'reference_mdk_engine.dart';
import '../intro/playback_metadata.dart';

/// Native adapters are reused, but the original PlayerFactory and its platform
/// availability rules are untouched. Only the opt-in reference player uses this.
class ReferencePlayerFactory {
  static bool mpvInitFailed = false, mdkInitFailed = false;
  static void clearMpvInitFailure() => mpvInitFailed = false;
  static void clearMdkInitFailure() => mdkInitFailed = false;
  static bool supportsMediaHeaders(PlayerKernel kernel) => true;
  static String? unavailableReason(PlayerKernel kernel) =>
      const ReferencePlayerKernelCatalog().unavailableReason(kernel);
  static bool isAvailable(PlayerKernel kernel) => switch (kernel) {
    PlayerKernel.avplayer => Platform.isIOS,
    PlayerKernel.mpv =>
      (Platform.isIOS || Platform.isAndroid) && !mpvInitFailed,
    PlayerKernel.mdk =>
      (Platform.isIOS || Platform.isAndroid) && !mdkInitFailed,
  };
  static AbstractPlayer? create(
    PlayerKernel kernel, {
    bool emulatorSurfacePreview = false,
  }) {
    if (!isAvailable(kernel)) return null;
    return switch (kernel) {
      PlayerKernel.avplayer => AvPlayer(),
      PlayerKernel.mpv => _ReferenceMpvPlayer(
        MediaKitMpvEngine.create(
          title: 'LumeBox · 参考播放器',
          emulatorSurfacePreview: Platform.isAndroid && emulatorSurfacePreview,
        ),
      ),
      PlayerKernel.mdk => ReferenceMdkEngine.create(),
    };
  }
}

class ReferencePlayerKernelCatalog implements PlayerKernelCatalog {
  const ReferencePlayerKernelCatalog();
  @override
  bool isAvailable(PlayerKernel kernel) =>
      ReferencePlayerFactory.isAvailable(kernel);
  @override
  String? unavailableReason(PlayerKernel kernel) => isAvailable(kernel)
      ? null
      : kernel == PlayerKernel.avplayer
      ? 'AVPlayer 由 iOS 系统提供，请在 iPhone 上验证'
      : '${kernel.label} 当前不可用，可手动重试或选择其他内核';
}

class _ReferenceMpvPlayer extends MpvPlayer implements IntroPlaybackMetadata {
  _ReferenceMpvPlayer(MpvEngine engine) : super(engine: engine);
  @override
  Future<Map<String, Object?>> introMetadata() async {
    final reader = engine;
    return reader is MediaKitMpvEngine ? reader.readIntroMetadata() : {};
  }

  @override
  Future<void> load(PlayerMedia media) async {
    final prefs = PlayerExperienceStore.current;
    await setBuffering(
      BufferingConfig(
        readAhead: Duration(seconds: prefs.mpvBufferSeconds),
        maxBufferBytes: prefs.mpvBufferMB * 1024 * 1024,
        maxBackBufferBytes: 0,
      ),
    );
    final writer = engine;
    if (writer is EnginePropertyCapable) {
      if (prefs.mpvRenderer == 'gpu-next') {
        LumeLog.warn(
          '[reference/mpv] gpu-next cannot replace the host texture renderer; using current Flutter texture output',
        );
      }
      try {
        for (final option in MpvConfOptions.parse(prefs.mpvConf).entries) {
          if (const [
            'vo',
            'wid',
            'opengl-cb',
            'input-default-bindings',
            'input-vo-keyboard',
          ].contains(option.key)) {
            LumeLog.warn(
              '[reference/mpv] Host-owned option ${option.key} was not changed',
            );
            continue;
          }
          final accepted = await (writer as EnginePropertyCapable)
              .setEngineProperty(option.key, option.value);
          if (!accepted) {
            LumeLog.warn(
              '[reference/mpv] Unsupported custom option: ${option.key}',
            );
          }
        }
      } catch (_) {
        LumeLog.warn(
          '[reference/mpv] Invalid custom configuration; using normal playback settings',
        );
      }
    }
    await super.load(media);
  }
}

/// A transient rate intentionally bypasses persistent speed quantization. It is
/// never written to either player's settings store, and release restores base.
class ReferenceTemporaryRate extends PlayerSettings {
  ReferenceTemporaryRate(PlayerSettings base, this.rate)
    : super(
        kernel: base.kernel,
        prefs: base.prefs,
        subtitlesEnabled: base.subtitlesEnabled,
        hardwareDecoding: base.hardwareDecoding,
      );
  final double rate;
  @override
  double get speed => rate.clamp(.25, 10);
}
