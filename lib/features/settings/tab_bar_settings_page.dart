import 'dart:math' as math;

import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/theme/frosted_settings.dart';
import '../shell/dock_native_glass.dart';
import '../shell/shell_dock_bar.dart';

import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

class TabBarSettingsPage extends StatelessWidget {
  const TabBarSettingsPage({super.key, this.controller});
  final ShellSettingsController? controller;
  @override
  Widget build(BuildContext context) => DockLiquidSettingsPage(
    controller: controller ?? ShellSettingsController.instance,
    entries: [
      for (final tab in ShellTab.all) _previewEntry(tab),
      ShellDockEntry.search,
    ],
  );
}

class DockLiquidSettingsPage extends StatelessWidget {
  const DockLiquidSettingsPage({
    super.key,
    required this.controller,
    required this.entries,
  });
  final ShellSettingsController controller;
  final List<ShellDockEntry> entries;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, FrostedSettings.instance]),
    builder: (context, _) {
      final appearance = controller.appearance;
      final liquid = appearance.liquid;
      Widget slider(DockLiquidParameter p) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(p.label)),
                Text(p.display(liquid.value(p))),
              ],
            ),
            Slider(
              key: ValueKey('dock-liquid-${p.name}'),
              value: liquid.value(p),
              min: p.min,
              max: p.max,
              divisions: p.milliseconds ? 350 : 100,
              onChanged: (value) => controller.setAppearance(
                controller.appearance.copyWith(
                  liquid: controller.appearance.liquid.withValue(p, value),
                ),
                persist: false,
              ),
              onChangeEnd: (_) =>
                  controller.setAppearance(controller.appearance),
            ),
            Text(
              p.description,
              style: TextStyle(
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
              ),
            ),
          ],
        ),
      );
      return GlassScaffold(
        title: '底栏液态动效',
        effectModule: GlassModule.settings,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DockAppearancePreview(
                  appearance: appearance,
                  entries: entries,
                  maxHeight: 220,
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('在上方按住或拖动体验。调节立即生效，并自动保存。'),
              ),
              Expanded(
                child: ListView(
                  children: [
                    if (!FrostedSettings.instance.frostedEnabled)
                      const SettingsNoteCard('毛玻璃总开关已关闭，参数仍会保存；重新开启后生效。'),
                    SwitchListTile.adaptive(
                      title: const Text('液态动效总开关'),
                      subtitle: const Text('控制底栏按压、拖动与回弹'),
                      value: appearance.animateSelection,
                      onChanged: (value) => controller.setAppearance(
                        controller.appearance.copyWith(animateSelection: value),
                      ),
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Expanded(child: Text('回弹时长')),
                              Text('${appearance.animationMs} ms'),
                            ],
                          ),
                          Slider(
                            key: const ValueKey('dock-liquid-settle-duration'),
                            min: 100,
                            max: 2000,
                            value: appearance.animationMs.toDouble(),
                            onChanged: appearance.animateSelection
                                ? (value) => controller.setAppearance(
                                    controller.appearance.copyWith(
                                      animationMs: value.round(),
                                    ),
                                    persist: false,
                                  )
                                : null,
                            onChangeEnd: (_) =>
                                controller.setAppearance(controller.appearance),
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('预设'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final preset in DockLiquidPreset.values)
                            ActionChip(
                              key: ValueKey(
                                'dock-liquid-preset-${preset.name}',
                              ),
                              avatar: const Icon(Icons.auto_awesome, size: 18),
                              label: Text(preset.label),
                              tooltip: preset.description,
                              onPressed: () => controller.setAppearance(
                                controller.appearance.copyWith(
                                  liquid: preset
                                      .build()
                                      .withGlassRenderer(liquid.glassRenderer)
                                      .withNativeGlassStyle(
                                        liquid.nativeGlassStyle,
                                      )
                                      .withReduceTransparency(
                                        liquid.reduceTransparency,
                                      )
                                      .withValue(
                                        DockLiquidParameter.nativeTint,
                                        liquid.value(
                                          DockLiquidParameter.nativeTint,
                                        ),
                                      ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('渲染方式（A/B 对比）'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final renderer in DockGlassRenderer.values)
                            ChoiceChip(
                              key: ValueKey(
                                'dock-glass-renderer-${renderer.name}',
                              ),
                              label: Text(renderer.label),
                              selected: liquid.glassRenderer == renderer,
                              onSelected: (_) => controller.setAppearance(
                                controller.appearance.copyWith(
                                  liquid: controller.appearance.liquid
                                      .withGlassRenderer(renderer),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                      child: Text(
                        DockNativeGlass.supported
                            ? 'iOS 26 使用系统液态玻璃，旧系统和厚实风格使用磨砂；图标与切换动效由应用绘制。'
                            : '当前设备不是 iPhone：选择“iOS 原生材质”会自动回退为 Flutter 自绘，便于在模拟器/桌面上先保存配置。',
                        style: TextStyle(
                          fontSize: 12,
                          color: LumeTheme.textSecondary,
                        ),
                      ),
                    ),
                    if (liquid.glassRenderer ==
                        DockGlassRenderer.nativeIos) ...[
                      const Divider(),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text('原生材质参数'),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final style in DockNativeGlassStyle.values)
                              ChoiceChip(
                                key: ValueKey(
                                  'dock-native-style-${style.name}',
                                ),
                                label: Text(style.label),
                                selected: liquid.nativeGlassStyle == style,
                                onSelected: (_) => controller.setAppearance(
                                  controller.appearance.copyWith(
                                    liquid: controller.appearance.liquid
                                        .withNativeGlassStyle(style),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      slider(DockLiquidParameter.nativeTint),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          '原生模式下“透镜折射/清澈”参数不生效；形状、白度、按压放大、整体提亮、阴影与原生材质参数仍可调。',
                          style: TextStyle(
                            fontSize: 12,
                            color: LumeTheme.textSecondary,
                          ),
                        ),
                      ),
                    ],
                    SwitchListTile.adaptive(
                      key: const ValueKey('dock-liquid-reduce-transparency'),
                      title: const Text('减少透明效果'),
                      subtitle: const Text(
                        '更白的底座、收敛的折射；iOS 系统“降低透明度”开启时也会自动生效',
                      ),
                      value: liquid.reduceTransparency,
                      onChanged: (value) => controller.setAppearance(
                        controller.appearance.copyWith(
                          liquid: controller.appearance.liquid
                              .withReduceTransparency(value),
                        ),
                      ),
                    ),
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('基础形状'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final shape in DockLensShape.values)
                            ChoiceChip(
                              key: ValueKey('dock-liquid-shape-${shape.name}'),
                              label: Text(shape.label),
                              selected: liquid.shape == shape,
                              onSelected: (_) => controller.setAppearance(
                                controller.appearance.copyWith(
                                  liquid: controller.appearance.liquid
                                      .withShape(shape),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SwitchListTile.adaptive(
                      key: const ValueKey('dock-liquid-free-deform'),
                      title: const Text('自由形变'),
                      subtitle: const Text('关闭时保持规则轮廓；开启后拖动才拉伸、倾斜与拖尾'),
                      value: liquid.freeDeform,
                      onChanged: (value) => controller.setAppearance(
                        controller.appearance.copyWith(
                          liquid: controller.appearance.liquid.withFreeDeform(
                            value,
                          ),
                        ),
                      ),
                    ),
                    for (final p in DockLiquidParameter.values.where(
                      (p) => p.effect == null && p.name.startsWith('shape'),
                    ))
                      slider(p),
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('跟手与回弹'),
                    ),
                    for (final p in DockLiquidParameter.values.where(
                      (p) => p.effect == null && !p.name.startsWith('shape'),
                    ))
                      slider(p),
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('效果与材质'),
                    ),
                    for (final effect in DockLiquidEffect.values) ...[
                      const Divider(),
                      SwitchListTile.adaptive(
                        key: ValueKey('dock-liquid-effect-${effect.name}'),
                        title: Text(effect.label),
                        subtitle: Text(effect.description),
                        value: liquid.enabled(effect),
                        onChanged: (value) => controller.setAppearance(
                          controller.appearance.copyWith(
                            liquid: controller.appearance.liquid.withEnabled(
                              effect,
                              value,
                            ),
                          ),
                        ),
                      ),
                      if (liquid.enabled(effect))
                        for (final p in DockLiquidParameter.values.where(
                          (p) =>
                              p.effect == effect &&
                              p != DockLiquidParameter.nativeTint,
                        ))
                          slider(p),
                    ],
                    TextButton.icon(
                      key: const ValueKey('dock-liquid-reset'),
                      onPressed: () => controller.setAppearance(
                        controller.appearance.copyWith(
                          liquid: const DockLiquidSettings(),
                        ),
                      ),
                      icon: const LumeIcon(
                        Icons.restore,
                        slot: 'tab_bar_settings_page.7',
                      ),
                      label: const Text('恢复液态参数默认值'),
                    ),
                    const SettingsFooterNote(
                      '只恢复本页的液态参数；白度、磨砂、尺寸、动效时长及页签顺序保留。'
                      '系统开启减少动态效果时，按压和拖动形变自动停止。',
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class DockAppearancePreview extends StatefulWidget {
  const DockAppearancePreview({
    super.key,
    this.maxHeight,
    this.reference = false,
    required this.appearance,
    required this.entries,
  });

  final DockAppearance appearance;
  final double? maxHeight;
  final bool reference;

  /// 当前可见的页签（顺序与真实 Dock 一致，至少 1 项）。
  final List<ShellDockEntry> entries;

  @override
  State<DockAppearancePreview> createState() => DockAppearancePreviewState();
}

class DockAppearancePreviewState extends State<DockAppearancePreview> {
  String _activeId = ShellTab.all.first.id;

  /// 选中项被用户隐藏后，回落到第一个仍可见的页签。
  String get _resolvedActiveId {
    if (widget.entries.isEmpty) return _activeId;
    if (widget.entries.any((entry) => entry.id == _activeId)) return _activeId;
    return widget.entries.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final appearance = widget.appearance;
    // 预览高度跟随「高度 + 正离底距离」增长：150pt 高、100pt 抬高时也能完整
    // 看到胶囊；位置计算与生产底栏共享，并限制在屏幕下沿。
    final previewHeight =
        200.0 +
        (appearance.height - 54).clamp(0, 96) +
        appearance.bottomFor(10);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: math.min(previewHeight, widget.maxHeight ?? previewHeight),
        child: FittedBox(
          fit: BoxFit.contain,
          child: ClipRRect(
            key: const ValueKey('dock-appearance-preview'),
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: constraints.maxWidth,
              height: previewHeight,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  const _PreviewPosterWall(),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ShellDockBar(
                      entries: widget.entries,
                      activeId: _resolvedActiveId,
                      onSelect: (id) {
                        if (id != ShellDockEntry.search.id) {
                          setState(() => _activeId = id);
                        }
                      },
                      appearance: appearance,
                      applyViewPadding: false,
                      bottomMargin: appearance.bottomFor(10),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .34),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          widget.reference ? '默认参照 · 自绘底栏' : '当前底栏 · 可交互',
                          style: const TextStyle(
                            fontSize: 10,
                            height: 1.2,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ShellDockEntry _previewEntry(ShellTab tab) {
  final (IconData icon, IconData selectedIcon) = switch (tab.id) {
    'comic' => (Icons.auto_stories_outlined, Icons.auto_stories_rounded),
    'video' => (
      Icons.play_circle_outline_rounded,
      Icons.play_circle_fill_rounded,
    ),
    'cat' => (Icons.pets_outlined, Icons.pets_rounded),
    _ => (Icons.settings_outlined, Icons.settings_rounded),
  };
  return ShellDockEntry(
    id: tab.id,
    label: tab.label,
    icon: icon,
    selectedIcon: selectedIcon,
  );
}

/// 预览背景：一张由海报拼成的彩色墙，底层再铺细斜纹。
///
/// 斜纹是给毛玻璃「对焦」用的：不模糊时是一根根细线，模糊后融成柔和的
/// 光带，滑块拖到 0 与 15 的差别一眼可见。
class _PreviewPosterWall extends StatelessWidget {
  const _PreviewPosterWall();

  static const List<(List<Color>, String, String)> _posters =
      <(List<Color>, String, String)>[
        (<Color>[Color(0xFF6C5CE7), Color(0xFFA29BFE)], '漫剧', '新番'),
        (<Color>[Color(0xFFFF7675), Color(0xFFFDA085)], '电影', '热映'),
        (<Color>[Color(0xFF00B894), Color(0xFF55EFC4)], '阅读', '连载'),
        (<Color>[Color(0xFF0984E3), Color(0xFF74B9FF)], '短剧', '推荐'),
      ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final poster in _posters)
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: poster.$1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            poster.$2,
                            style: TextStyle(
                              fontSize: 22,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                              color: Colors.white.withValues(alpha: .92),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            poster.$3,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: .64),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 104,
          child: CustomPaint(painter: _PreviewStripePainter()),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.transparent,
                    Colors.black.withValues(alpha: .18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewStripePainter extends CustomPainter {
  const _PreviewStripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .16)
      ..strokeWidth = 2;
    for (var x = -size.height; x < size.width; x += 14) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewStripePainter oldDelegate) => false;
}
