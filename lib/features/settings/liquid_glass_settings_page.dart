import 'package:flutter/material.dart';

import '../../core/theme/frosted_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/shell/shell_settings.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import 'navigation_settings_page.dart';
import 'dock_layout_settings_page.dart';
import 'tab_bar_settings_page.dart';
import 'settings_ui.dart';

class LiquidGlassSettingsPage extends StatefulWidget {
  const LiquidGlassSettingsPage({super.key});
  @override
  State<LiquidGlassSettingsPage> createState() =>
      _LiquidGlassSettingsPageState();
}

class _LiquidGlassSettingsPageState extends State<LiquidGlassSettingsPage> {
  GlassModule module = GlassModule.all;
  GlassPart? part;
  final settings = FrostedSettings.instance;
  bool supports(GlassParameter parameter) {
    if (part == GlassPart.dock) {
      return [
        GlassParameter.blur,
        GlassParameter.opacity,
        GlassParameter.border,
        GlassParameter.shadow,
      ].contains(parameter);
    }
    if (part == GlassPart.navigation ||
        part == GlassPart.home ||
        part == GlassPart.panels) {
      return ![
        GlassParameter.pressScale,
        GlassParameter.duration,
        GlassParameter.refraction,
        GlassParameter.dispersion,
      ].contains(parameter);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '液态玻璃管理',
    effectModule: GlassModule.settings,
    behindBar: true,
    child: ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final style = settings.style(module, part);
        void update(LiquidGlassStyle value, {bool persist = true}) =>
            settings.setStyle(module, part, value, persist: persist);
        return ListView(
          padding: GlassScaffold.barInset(context)
              .add(const EdgeInsets.fromLTRB(20, 20, 20, 36)),
          children: [
            const SettingsPageIntro(
              title: '光感与层次',
              description: '通用材质统一生效，也可以为不同模块与部件单独微调。',
            ),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    title: const Text('毛玻璃'),
                    subtitle: const Text('关闭后使用实色表面，内容和操作保持不变'),
                    value: settings.frostedEnabled,
                    onChanged: settings.setFrostedEnabled,
                  ),
                  SwitchListTile.adaptive(
                    title: const Text('减少透明效果'),
                    subtitle: const Text('使用更清楚的实色表面；高对比度模式自动启用'),
                    value: settings.reduceTransparency,
                    onChanged: settings.setReduceTransparency,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('调整范围', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<GlassModule>(
                    initialValue: module,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '应用模块'),
                    items: [
                      for (final item in GlassModule.values)
                        DropdownMenuItem(value: item, child: Text(item.label)),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => module = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: part?.name ?? 'all',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '界面部件'),
                    items: [
                      const DropdownMenuItem(value: 'all', child: Text('全部部件')),
                      for (final item in [
                        GlassPart.navigation,
                        GlassPart.home,
                        GlassPart.dock,
                        GlassPart.cards,
                        GlassPart.panels,
                      ])
                        DropdownMenuItem(
                          value: item.name,
                          child: Text(item.label),
                        ),
                    ],
                    onChanged: (v) => setState(
                      () => part = v == 'all'
                          ? null
                          : GlassPart.values.firstWhere((p) => p.name == v),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    settings.hasOverride(module, part)
                        ? '当前范围使用独立配置'
                        : '当前范围继承上级配置；调节后建立独立配置',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      LumeTheme.accent.withValues(alpha: .5),
                      const Color(0xFF81C7BE),
                      const Color(0xFFEDC9D6),
                    ],
                  ),
                ),
                padding: const EdgeInsets.all(24),
                child: ModuleGlassScope(
                  module: module,
                  part: part,
                  child: FrostedGlassWidget(
                    part: part,
                    interactive: true,
                    child: const Padding(
                      padding: EdgeInsets.all(22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.water_drop_outlined, size: 30),
                          SizedBox(height: 10),
                          Text('轻按体验玻璃质感'),
                          SizedBox(height: 6),
                          Text('模糊 · 反光 · 折射', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    title: const Text('在此范围启用玻璃'),
                    value: style.enabled,
                    onChanged: (v) => update(style.copyWith(enabled: v)),
                  ),
                  SwitchListTile.adaptive(
                    title: const Text('轻按液态反馈'),
                    subtitle: const Text('应用于可点击卡片；系统减少动态效果时停止'),
                    value: style.motion,
                    onChanged: style.enabled
                        ? (v) => update(style.copyWith(motion: v))
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            for (final group in <String, List<GlassParameter>>{
              '通透与色彩': [
                GlassParameter.blur,
                GlassParameter.opacity,
                GlassParameter.tint,
                GlassParameter.saturation,
              ],
              '边缘与光影': [
                GlassParameter.border,
                GlassParameter.borderWidth,
                GlassParameter.highlight,
                GlassParameter.shadow,
                GlassParameter.shadowBlur,
                GlassParameter.radius,
              ],
              '按压与透镜': [
                GlassParameter.pressScale,
                GlassParameter.duration,
                GlassParameter.refraction,
                GlassParameter.dispersion,
              ],
            }.entries)
              if (group.value.any(supports))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GlassCard(
                    padding: EdgeInsets.zero,
                    child: ExpansionTile(
                      title: Text(group.key),
                      initiallyExpanded: group.key == '通透与色彩',
                      children: [
                        for (final p in group.value.where(supports))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: Text(p.label)),
                                    Text(
                                      p.display(style.value(p)),
                                      style: TextStyle(
                                        color: LumeTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  key: ValueKey('glass-${p.name}'),
                                  min: p.min,
                                  max: p.max,
                                  value: style.value(p),
                                  onChanged:
                                      settings.frostedEnabled &&
                                          style.enabled &&
                                          !settings.reduceTransparency
                                      ? (v) => update(
                                          settings
                                              .style(module, part)
                                              .withValue(p, v),
                                          persist: false,
                                        )
                                      : null,
                                  onChangeEnd: (_) => settings.save(),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            SettingsEntryCard(
              icon: Icons.space_dashboard_outlined,
              title: '底栏尺寸与位置',
              subtitle: '宽高、左右边距、上下左右偏移与默认参照',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DockLayoutSettingsPage(
                    controller: ShellSettingsController.instance,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SettingsEntryCard(
              icon: Icons.bubble_chart_outlined,
              title: '底栏液态动效',
              subtitle: '水滴、胶囊、折射、拖尾与回弹的完整细分参数',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DockLiquidSettingsPage(
                    controller: ShellSettingsController.instance,
                    entries: navigationPreviewEntries(),
                  ),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => settings.resetStyle(module, part),
              icon: const Icon(Icons.restart_alt),
              label: const Text('恢复当前范围默认'),
            ),
            const SettingsFooterNote(
              '单个范围重置后恢复继承。通用参数作用于应用自绘玻璃；原生系统导航的材质由系统决定。正文、图片和视频画面不加滤镜，透镜仅在按压可点击表面时出现。',
            ),
          ],
        );
      },
    ),
  );
}
