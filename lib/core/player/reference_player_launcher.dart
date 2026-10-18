import 'abstract_player.dart';
import 'player_experience_store.dart';
import 'player_kernel_launcher.dart' show PlayerLaunch;
import 'player_settings.dart';
import 'reference_player_factory.dart';

/// The reference player does not trip the original player's circuit breakers.
class ReferencePlayerLauncher {
  ReferencePlayerLauncher({AbstractPlayer? Function(PlayerKernel)? factory})
    : _factory = factory ?? ReferencePlayerFactory.create;
  final AbstractPlayer? Function(PlayerKernel) _factory;
  Future<PlayerLaunch?> launch(PlayerKernel preferred) async {
    final choices = [
      preferred,
      if (PlayerExperienceStore.current.autoKernelSwitch)
        ...PlayerKernel.values.where((k) => k != preferred),
    ];
    for (final kernel in choices) {
      AbstractPlayer? player;
      // This construction itself runs after the UI has had a frame to paint.
      final pending = Future<AbstractPlayer?>(() => _factory(kernel));
      var abandoned = false;
      pending.then((latePlayer) {
        if (abandoned) latePlayer?.dispose();
      }, onError: (_) {});
      try {
        player = await pending.timeout(const Duration(seconds: 8));
      } catch (_) {
        abandoned = true;
        continue;
      }
      if (player != null) {
        return PlayerLaunch(
          player: player,
          kernel: kernel,
          fallbackFrom: kernel == preferred ? null : preferred,
          message: kernel == preferred
              ? ''
              : '${preferred.label} 无法启动，参考播放器已切换 ${kernel.label}',
        );
      }
    }
    return null;
  }
}
