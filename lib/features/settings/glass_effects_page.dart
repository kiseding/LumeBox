import '../../core/theme/liquid_performance_guard.dart';

import 'package:flutter/material.dart';

import '../../core/theme/glass_effects_settings.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/liquid_glass_widget.dart';

class GlassEffectsPage extends StatefulWidget {
  const GlassEffectsPage({super.key});
  @override
  State<GlassEffectsPage> createState() => _GlassEffectsPageState();
}

class _GlassEffectsPageState extends State<GlassEffectsPage> {
  GlassModule module = GlassModule.all;
  final settings = GlassEffectsSettings.instance;
  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '全 App 玻璃效果',
    child: ListenableBuilder(
      listenable: Listenable.merge([settings, LiquidPerformanceGuard.instance]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile.adaptive(
            title: const Text('新毛玻璃总开关'),
            subtitle: const Text('关闭后所有新毛玻璃部位回到原有 UI'),
            value: settings.frostedEnabled,
            onChanged: settings.setFrostedEnabled,
          ),
          SwitchListTile.adaptive(
            title: const Text('动态液态玻璃总开关'),
            subtitle: const Text('关闭后所有液态部位回到原有 UI'),
            value: settings.liquidEnabled,
            onChanged: settings.setLiquidEnabled,
          ),
          ListTile(
            title: const Text('液态效果性能保护'),
            subtitle: Text(LiquidPerformanceGuard.instance.status),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<GlassModule>(
            initialValue: module,
            decoration: const InputDecoration(labelText: '选择模块'),
            items: [
              for (final value in GlassModule.values)
                DropdownMenuItem(value: value, child: Text(value.label)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => module = value);
            },
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('“全 App 通用”用于统一设置；各模块可以单独覆盖。关闭部位开关时直接使用原有界面。'),
          ),
          SwitchListTile.adaptive(
            title: Text('${module.label}效果开关'),
            value: settings.moduleEnabled(module),
            onChanged: (v) => settings.setModuleEnabled(module, v),
          ),
          for (final part in GlassPart.values) _part(part),
          const Divider(height: 28),
          ExpansionTile(
            title: const Text('播放器专用部位'),
            subtitle: const Text('未单独覆盖模块设置时使用'),
            children: [
              SwitchListTile.adaptive(
                title: const Text('播放器弹窗使用新毛玻璃'),
                value: settings.playerFrostedEnabled,
                onChanged: settings.setPlayerFrostedEnabled,
              ),
              _area(GlassArea.videoSettings),
              for (final area in GlassArea.values.where((area) => area.liquid))
                _area(area),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '所有列出的部位均可选择新毛玻璃或液态效果。较多效果或持续卡顿时自动降帧、减少模糊与折射，严重时暂用普通 UI；不会修改你保存的开关和参数。原有悬浮模块与微磨砂保留。\n\n对应部位在页面出现时生效。首页常驻播放条保持原有微磨砂；“主页播放条展开的完整播放器”当前尚未接入。',
            ),
          ),
        ],
      ),
    ),
  );
  Widget _part(GlassPart part) {
    final tune = settings.moduleTuning(module, part);
    void update(GlassTuning next) {
      settings.setModule(module, part, next);
    }

    final master = tune.liquid
        ? settings.liquidEnabled
        : settings.frostedEnabled;
    return ExpansionTile(
      key: ValueKey('${module.name}.${part.name}'),
      title: Text(part.label),
      subtitle: Text(
        !tune.enabled
            ? '原有 UI'
            : !master
            ? '总开关已关闭'
            : tune.liquid
            ? '动态液态玻璃'
            : '新毛玻璃',
      ),
      trailing: Switch(
        value: tune.enabled,
        onChanged: (v) => update(tune.copyWith(enabled: v)),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              DropdownButtonFormField<bool>(
                key: ValueKey('${module.name}.${part.name}.${tune.liquid}'),
                initialValue: tune.liquid,
                decoration: const InputDecoration(labelText: '效果类型'),
                items: [
                  const DropdownMenuItem(value: false, child: Text('新毛玻璃')),
                  if (part.allowsLiquid)
                    const DropdownMenuItem(value: true, child: Text('动态液态玻璃')),
                ],
                onChanged: !tune.enabled
                    ? null
                    : (value) {
                        if (value != null) update(tune.copyWith(liquid: value));
                      },
              ),
              _preview(tune, liquid: tune.liquid),
              ..._controls(tune, update, liquid: tune.liquid),
              TextButton(
                onPressed: () => update(
                  GlassTuning(enabled: tune.enabled, liquid: tune.liquid),
                ),
                child: const Text('恢复默认参数'),
              ),
              if (module != GlassModule.all)
                TextButton(
                  onPressed: () => settings.resetModule(module, part),
                  child: const Text('恢复使用全 App 通用设置'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _area(GlassArea area) {
    final tune = settings.tuning(area);
    void update(GlassTuning next) {
      settings.setArea(area, next);
    }

    return ExpansionTile(
      title: Text(area.label),
      trailing: Switch(
        value: tune.enabled,
        onChanged: (v) => update(tune.copyWith(enabled: v)),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              _preview(tune, liquid: area.liquid),
              ..._controls(tune, update, liquid: area.liquid),
              TextButton(
                onPressed: () => update(GlassTuning(enabled: tune.enabled)),
                child: const Text('恢复默认参数'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _preview(GlassTuning tune, {required bool liquid}) {
    const sample = SizedBox(
      width: double.infinity,
      height: 72,
      child: Center(
        child: Text(
          '效果预览',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
        ),
      ),
    );
    final enabled =
        tune.enabled &&
        (liquid ? settings.liquidEnabled : settings.frostedEnabled);
    final surface = !enabled
        ? const ColoredBox(color: Color(0xff343a46), child: sample)
        : liquid
        ? LiquidGlassWidget(
            blur: tune.blur,
            opacity: tune.opacity,
            radius: tune.radius,
            highlight: tune.highlight,
            distort: tune.distort,
            speed: tune.speed,
            border: tune.border,
            child: sample,
          )
        : FrostedGlassWidget(
            blur: tune.blur,
            opacity: tune.opacity,
            radius: tune.radius,
            border: tune.border,
            child: sample,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [
                    Color(0xff506ce0),
                    Color(0xffc15d97),
                    Color(0xff30a9a0),
                  ],
                ),
              ),
            ),
          ),
          surface,
        ],
      ),
    );
  }

  List<Widget> _controls(
    GlassTuning tune,
    void Function(GlassTuning) update, {
    required bool liquid,
  }) {
    Widget slider(
      String title,
      double value,
      double max,
      void Function(double) changed, {
      double min = 0,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title：${value.toStringAsFixed(2)}'),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: tune.enabled ? changed : null,
        ),
      ],
    );
    return [
      slider('模糊强度', tune.blur, 40, (v) => update(tune.copyWith(blur: v))),
      slider('透明度', tune.opacity, 1, (v) => update(tune.copyWith(opacity: v))),
      slider('圆角', tune.radius, 40, (v) => update(tune.copyWith(radius: v))),
      if (liquid) ...[
        slider(
          '高光强度',
          tune.highlight,
          1,
          (v) => update(tune.copyWith(highlight: v)),
        ),
        slider(
          '折射扭曲',
          tune.distort,
          1,
          (v) => update(tune.copyWith(distort: v)),
        ),
        slider(
          '动画速度',
          tune.speed,
          2,
          (v) => update(tune.copyWith(speed: v)),
          min: .25,
        ),
      ],
      SwitchListTile.adaptive(
        title: const Text('显示边框'),
        value: tune.border,
        onChanged: tune.enabled
            ? (v) => update(tune.copyWith(border: v))
            : null,
      ),
    ];
  }
}
