import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../shared/widgets/glass_card.dart';
import 'navigation_settings_page.dart';
import 'settings_ui.dart';
import 'tab_bar_settings_page.dart';

/// Geometry uses the production dock's layout calculation and persistence.
class DockLayoutSettingsPage extends StatelessWidget {
  const DockLayoutSettingsPage({super.key, required this.controller});
  final ShellSettingsController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final appearance = controller.appearance;
      Widget slider(
        String id,
        String label,
        double value,
        double min,
        double max,
        DockAppearance Function(double) change,
      ) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label · ${value.round()} pt'),
            Slider(
              key: ValueKey('dock-layout-$id'),
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: (max - min).round(),
              onChanged: (v) =>
                  controller.setAppearance(change(v), persist: false),
              onChangeEnd: (_) =>
                  controller.setAppearance(controller.appearance),
            ),
          ],
        ),
      );
      return GlassScaffold(
        title: '底栏尺寸与位置',
        behindBar: true,
        child: ListView(
          padding: GlassScaffold.barInset(context)
              .add(const EdgeInsets.fromLTRB(20, 16, 20, 36)),
          children: [
            const SettingsPageIntro(
              title: '让导航恰到好处',
              description: '自绘底栏实时预览，拖动结束后自动保存。单位为逻辑像素 pt。',
            ),
            if (controller.settings.nativeNavigation.enabled)
              const SettingsNoteCard('当前使用原生系统导航。以下尺寸仅作用于自绘底栏；关闭原生系统导航后应用。'),
            DockAppearancePreview(
              appearance: appearance,
              entries: navigationPreviewEntries(),
              maxHeight: 240,
            ),
            const SizedBox(height: 14),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('默认参照', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 350 / 214,
                      child: Image.asset(
                        'assets/reference/dock_default.png',
                        semanticLabel: '默认自绘底栏效果参照',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '默认：高度 54 · 左右各 24 · 自动宽度 · 离安全区 4\n本地 Flutter 组件渲染，非 iPhone 真机截图。',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    title: const Text('自动宽度'),
                    subtitle: const Text('按屏幕与左右边距撑满；关闭后指定宽度'),
                    value: appearance.preferredWidth == 0,
                    onChanged: (v) => controller.setAppearance(
                      appearance.copyWith(
                        preferredWidth: v
                            ? 0
                            : appearance
                                  .layoutFor(MediaQuery.sizeOf(context).width)
                                  .width,
                      ),
                    ),
                  ),
                  if (appearance.preferredWidth > 0)
                    slider(
                      'width',
                      '指定宽度',
                      appearance.preferredWidth,
                      120,
                      1000,
                      (v) => appearance.copyWith(preferredWidth: v),
                    ),
                  slider(
                    'height',
                    '底栏高度',
                    appearance.height,
                    40,
                    150,
                    (v) => appearance.copyWith(height: v),
                  ),
                  slider(
                    'left',
                    '左侧边距',
                    appearance.effectiveLeftMargin,
                    0,
                    100,
                    (v) => appearance.copyWith(leftMargin: v),
                  ),
                  slider(
                    'right',
                    '右侧边距',
                    appearance.effectiveRightMargin,
                    0,
                    100,
                    (v) => appearance.copyWith(rightMargin: v),
                  ),
                  slider(
                    'horizontal',
                    '横向偏移（正值向右）',
                    appearance.horizontalOffset,
                    -100,
                    100,
                    (v) => appearance.copyWith(horizontalOffset: v),
                  ),
                  slider(
                    'vertical',
                    '纵向偏移（正值向下）',
                    appearance.verticalOffset,
                    -80,
                    80,
                    (v) => appearance.copyWith(verticalOffset: v),
                  ),
                  slider(
                    'gap',
                    '离底安全区距离',
                    appearance.safeGap,
                    -50,
                    100,
                    (v) => appearance.copyWith(safeGap: v),
                  ),
                ],
              ),
            ),
            const SettingsFooterNote(
              '指定宽度受屏幕可用空间限制，左右边距之外的余量居中分配。偏移在边界内生效，底栏下缘不会移出屏幕；内容避让随高度与位置同步更新。预览缩放展示，实际尺寸以所在设备为准。',
            ),
            TextButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('恢复尺寸与位置默认'),
              onPressed: () => controller.setAppearance(
                appearance.copyWith(
                  horizontalMargin: 24,
                  leftMargin: 24,
                  rightMargin: 24,
                  preferredWidth: 0,
                  horizontalOffset: 0,
                  verticalOffset: 0,
                  height: 54,
                  safeGap: 4,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
