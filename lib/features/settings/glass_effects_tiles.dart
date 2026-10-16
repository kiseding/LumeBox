import 'glass_effects_page.dart';

import 'package:flutter/material.dart';

import '../../core/theme/glass_effects_settings.dart';

class LiquidGlassSettingsTile extends StatelessWidget {
  const LiquidGlassSettingsTile({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: GlassEffectsSettings.instance,
    builder: (context, _) => Column(
      children: [
        SwitchListTile.adaptive(
          title: const Text('动态液态玻璃效果'),
          subtitle: const Text('仅用于单独接入的小型装饰，关闭时使用原有界面'),
          value: GlassEffectsSettings.instance.liquidEnabled,
          onChanged: GlassEffectsSettings.instance.setLiquidEnabled,
        ),
        ListTile(
          title: const Text('玻璃效果作用部位与强度'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const GlassEffectsPage()),
          ),
        ),
      ],
    ),
  );
}

class PlayerFrostedSettingsTile extends StatelessWidget {
  const PlayerFrostedSettingsTile({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: GlassEffectsSettings.instance,
    builder: (context, _) => SwitchListTile.adaptive(
      title: const Text('播放器弹窗使用新毛玻璃'),
      subtitle: const Text('关闭时使用原有弹窗效果与悬浮面板配置'),
      value: GlassEffectsSettings.instance.playerFrostedEnabled,
      onChanged: GlassEffectsSettings.instance.setPlayerFrostedEnabled,
    ),
  );
}
