import 'package:flutter/material.dart';

import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/glass_card.dart';

class FloatingSettingsPage extends StatelessWidget {
  const FloatingSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '悬浮模块',
    child: ListenableBuilder(
      listenable: FloatingModules.instance,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('数值实时生效，返回后自动保留。向下偏移为正值。首页合并顶部使用“首页功能、分类与筛选”的设置。'),
          for (final module in FloatingModule.values) _module(context, module),
        ],
      ),
    ),
  );
  Widget _module(BuildContext context, FloatingModule module) {
    final controller = FloatingModules.instance;
    final style = controller.style(module);
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      FloatingStyle Function(double) change,
    ) => Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(value.toStringAsFixed(0)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: (v) => controller.set(module, change(v)),
          onChangeEnd: (_) => controller.save(),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: GlassCard(
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: Text(module.label)),
                TextButton(
                  onPressed: () {
                    controller.reset(module);
                    controller.save();
                  },
                  child: const Text('重置'),
                ),
              ],
            ),
            Transform.translate(
              offset: style.offset,
              child: GlassPanel(
                module: null,
                radius: 20,
                color: Theme.of(context).colorScheme.surface
                    .withValues(alpha: style.opacity),
                blur: style.blur,
                padding: const EdgeInsets.all(12),
                child: const Text('悬浮效果预览'),
              ),
            ),
            slider(
              '透明度（100 为完全透明）',
              (1 - style.opacity) * 100,
              0,
              100,
              (v) => style.copyWith(opacity: 1 - v / 100),
            ),
            slider('水平位置', style.x, -40, 40, (v) => style.copyWith(x: v)),
            slider(
              '垂直位置',
              style.y.clamp(-40, module == FloatingModule.dock ? 20 : 80),
              -40,
              module == FloatingModule.dock ? 20 : 80,
              (v) => style.copyWith(y: v),
            ),
            slider('磨砂强度', style.blur, 0, 30, (v) => style.copyWith(blur: v)),
          ],
        ),
      ),
    );
  }
}
