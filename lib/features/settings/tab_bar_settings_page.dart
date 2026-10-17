import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/dock_handle_button.dart';
import '../../shared/widgets/glass_card.dart';

/// 底部导航栏管理：**每个页签独立开关 + 拖拽排序 + 外观材质**。
///
/// ## 外观与材质
///
/// 尺寸（左右留白 / 高度 / 离底距离）、玻璃边缘高光、投影浓度、选中动效与时长
/// 都在本页调节，实时写回 [ShellSettingsController]；玻璃白度与磨砂强度与
/// 「设置 → 悬浮模块」共用同一份 [FloatingModules] 数据，不存第二份真相。
///
/// ## 两条硬约束（界面上都要说清）
///
/// 1. **至少保留 1 个页签**：全部关掉导航栏就空了，用户再也点不到任何入口。
///    因此最后一个可见页签的开关是**置灰**的，并说明原因（不是「点了没反应」）。
/// 2. **隐藏「设置」会留一个恢复入口**：设置页是进入本页的唯一入口。把它藏起来
///    之后没法再回来开别的页签——所以壳层会在左下角留一个小的设置按钮。
///    这一点必须写在界面上，否则用户会以为「隐藏设置 = 以后再也改不了导航栏」。
///
/// ## 实时生效
///
/// 每次改动直接写进 [ShellSettingsController]（它通知壳层重建），**不需要点保存、
/// 不需要重启**。这也是不做「保存/取消」按钮的原因：拖一下就立刻能看到底部变化，
/// 比「改完再确认」更符合拖拽这种直接操作的手感。
class TabBarSettingsPage extends StatelessWidget {
  const TabBarSettingsPage({super.key, this.controller});

  /// 设置控制器（测试可注入）；为空时用应用级单例。
  final ShellSettingsController? controller;

  ShellSettingsController get _controller =>
      controller ?? ShellSettingsController.instance;

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      effectModule: GlassModule.settings,
      behindBar: true,
      title: '底部导航栏管理',
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final tabs = _controller.tabs;
    final visibleCount = tabs.where((tab) => tab.visible).length;
    final settingsHidden = !_controller.settingsVisible;

    return ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
      children: <Widget>[
        _buildIntro(visibleCount),
        const SizedBox(height: 12),
        // 拖拽排序：ReorderableListView 需要有限高度，这里用 shrinkWrap
        // 嵌在 ListView 里（本页条目固定 5 条，不存在长列表性能问题）。
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: tabs.length,
          // onReorderItem（不是已废弃的 onReorder）：它给的 newIndex 已经是
          // 「移动后的最终下标」，与 ShellSettings.withMove 的语义一致，
          // 调用方不必自己处理 off-by-one。
          onReorderItem: (from, to) => _controller.move(from, to),
          itemBuilder: (context, index) {
            final tab = tabs[index];
            return _TabTile(
              key: ValueKey<String>('tab.${tab.id}'),
              index: index,
              config: tab,
              // 「至少保留 1 个」：最后一个可见项不许关。
              canHide: _controller.canHide(tab.id),
              onToggle: (value) => _toggle(context, tab.id, value),
            );
          },
        ),
        if (settingsHidden) ...<Widget>[
          const SizedBox(height: 12),
          const _SettingsHiddenNotice(),
        ],
        const SizedBox(height: 12),
        _buildAppearance(context),
        const SizedBox(height: 12),
        _buildHandleStyles(context),
        const SizedBox(height: 12),
        _buildFooter(context),
      ],
    );
  }

  Future<void> _toggle(BuildContext context, String id, bool value) async {
    final accepted = await _controller.setVisible(id, value);
    if (accepted || !context.mounted) return;
    // 被「至少保留 1 个」拒绝：明确告诉用户为什么，而不是让开关弹回去。
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text(ShellSettings.lastTabMessage)));
  }

  Widget _buildIntro(int visibleCount) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '当前显示 $visibleCount 个页签',
            style: TextStyle(
              fontSize: LumeTypography.titleSize,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '拖动手柄调整顺序，开关控制显示与隐藏。改动立即生效，不用重启 App。'
            '至少要保留 1 个页签，否则底部导航就空了。',
            style: TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: LumeTypography.descriptionSize,
              color: LumeTheme.descriptionColor,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  /// 外观与材质：尺寸 / 玻璃边缘 / 投影 / 点击动效。
  ///
  /// 白度与磨砂读写的仍是 [FloatingModules] 里「底部导航」那一份值（与
  /// 「设置 → 悬浮模块」同源），其余参数在 [ShellSettingsController]。
  Widget _buildAppearance(BuildContext context) {
    return ListenableBuilder(
      listenable: FloatingModules.instance,
      builder: (context, _) {
        final appearance = _controller.appearance;
        final modules = FloatingModules.instance;
        final style = modules.style(FloatingModule.dock);
        return GlassCard(
          radius: 14,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '外观与材质',
                style: TextStyle(
                  fontSize: LumeTypography.titleSize,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '调整底部 Dock 的尺寸与玻璃质感，改动立即生效。'
                '深色主题下白边会按比例柔化，避免在暗底上变成硬描边。',
                style: TextStyle(
                  fontWeight: FontWeight.w400,
                  fontSize: LumeTypography.descriptionSize,
                  color: LumeTheme.descriptionColor,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              _DockAppearancePreview(appearance: appearance, style: style),
              const SizedBox(height: 14),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-opacity'),
                label: '玻璃白度',
                value: style.opacity,
                min: .3,
                max: .9,
                divisions: 60,
                display: '${(style.opacity * 100).round()}%',
                onChanged: (value) => modules.set(
                  FloatingModule.dock,
                  style.copyWith(opacity: value),
                ),
                onChangeEnd: (_) => modules.save(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-blur'),
                label: '磨砂强度',
                value: style.blur,
                min: 0,
                max: 15,
                divisions: 15,
                display: style.blur.toStringAsFixed(0),
                onChanged: (value) => modules.set(
                  FloatingModule.dock,
                  style.copyWith(blur: value),
                ),
                onChangeEnd: (_) => modules.save(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-border'),
                label: '边缘高光',
                value: appearance.borderOpacity,
                min: 0,
                max: .8,
                divisions: 16,
                display: '${(appearance.borderOpacity * 100).round()}%',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(borderOpacity: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-shadow'),
                label: '阴影浓度',
                value: appearance.shadowOpacity,
                min: 0,
                max: .15,
                divisions: 15,
                display: '${(appearance.shadowOpacity * 100).round()}%',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(shadowOpacity: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-margin'),
                label: '左右留白',
                value: appearance.horizontalMargin,
                min: 16,
                max: 40,
                divisions: 24,
                display: '${appearance.horizontalMargin.round()} pt',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(horizontalMargin: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-height'),
                label: '导航栏高度',
                value: appearance.height,
                min: 48,
                max: 64,
                divisions: 16,
                display: '${appearance.height.round()} pt',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(height: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              _appearanceSlider(
                key: const ValueKey('dock-appearance-gap'),
                label: '离底部距离',
                value: appearance.safeGap,
                min: 0,
                max: 12,
                divisions: 12,
                display: '${appearance.safeGap.round()} pt',
                onChanged: (value) => _controller.setAppearance(
                  _controller.appearance.copyWith(safeGap: value),
                  persist: false,
                ),
                onChangeEnd: (_) => _controller.saveAppearance(),
              ),
              // 用普通 Row 而不是 SwitchListTile：ListTile 会注入自己的
              // titleTextStyle（不跟随页面字体），截图/自定义字体下会掉字。
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '点击弹跳动效',
                          style: TextStyle(
                            fontSize: LumeTypography.bodySize,
                            fontWeight: FontWeight.w500,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '切换页签时选中底座像水滴一样轻微回弹',
                          style: TextStyle(
                            fontSize: LumeTypography.descriptionSize,
                            color: LumeTheme.descriptionColor,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: appearance.animateSelection,
                    onChanged: (value) => _controller.setAppearance(
                      _controller.appearance.copyWith(animateSelection: value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (appearance.animateSelection)
                _appearanceSlider(
                  key: const ValueKey('dock-appearance-duration'),
                  label: '动效时长',
                  value: appearance.animationMs.toDouble(),
                  min: 150,
                  max: 400,
                  divisions: 10,
                  display: '${appearance.animationMs} ms',
                  onChanged: (value) => _controller.setAppearance(
                    _controller.appearance.copyWith(animationMs: value.round()),
                    persist: false,
                  ),
                  onChangeEnd: (_) => _controller.saveAppearance(),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _resetAppearance,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('恢复材质默认'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _resetAppearance() async {
    await _controller.setAppearance(DockAppearance.defaults);
    final modules = FloatingModules.instance;
    modules.set(
      FloatingModule.dock,
      modules
          .style(FloatingModule.dock)
          .copyWith(
            opacity: FloatingStyle.dockDefault.opacity,
            blur: FloatingStyle.dockDefault.blur,
          ),
    );
    modules.save();
  }

  Widget _appearanceSlider({
    Key? key,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: LumeTypography.bodySize,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            Text(
              display,
              style: TextStyle(
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.textSecondary,
              ),
            ),
          ],
        ),
        Slider(
          key: key,
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  Widget _buildHandleStyles(BuildContext context) {
    final selected = _controller.handleStyle;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '收起悬浮球',
            style: TextStyle(
              fontSize: LumeTypography.titleSize,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '导航栏滚动收起时，左下角悬浮球的样式。点一下立即生效；'
            '不用时会半透明，向右滑动或点击都能展开导航。',
            style: TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: LumeTypography.descriptionSize,
              color: LumeTheme.descriptionColor,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          for (final style in DockHandleStyle.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _HandleStyleOption(
                style: style,
                selected: style == selected,
                onTap: () => _controller.setHandleStyle(style),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '说明',
            style: TextStyle(
              fontSize: LumeTypography.bodySize,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '· 隐藏某个板块只是把它从底部导航里收起来，数据、缓存与图源都不受影响，'
            '随时可以再打开；\n'
            '· 桌面端（Windows / macOS）用的是左侧栏，顺序跟随这里的设置；\n'
            '· 隐藏「设置」后，左下角会出现一个小的设置按钮，点它回来改回这里。',
            style: TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: LumeTypography.descriptionSize,
              color: LumeTheme.descriptionColor,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _controller.restoreDefaults(),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复默认（全部显示）'),
          ),
        ],
      ),
    );
  }
}

/// 一行页签：拖拽手柄 + 名称 + 开关。
class _TabTile extends StatelessWidget {
  const _TabTile({
    super.key,
    required this.index,
    required this.config,
    required this.canHide,
    required this.onToggle,
  });

  final int index;
  final ShellTabConfig config;

  /// 是否允许被关掉（最后一个可见项不允许）。
  final bool canHide;

  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final tab = ShellTab.byId(config.id);
    final label = tab?.label ?? config.id;
    final isLastVisible = config.visible && !canHide;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: <Widget>[
            // 拖拽手柄：显式的拖动区，避免与开关的点击手势打架。
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: Icon(
                  Icons.drag_handle,
                  size: 20,
                  color: LumeTheme.textHint,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: LumeTypography.titleSize,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                  if (isLastVisible) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      '最后一个显示的页签，不能关掉',
                      style: TextStyle(
                        fontWeight: FontWeight.w400,
                        fontSize: LumeTypography.descriptionSize,
                        height: 1.5,
                        color: LumeTheme.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: config.visible,
              // 最后一颗开关置灰：点不动比「点了弹提示再弹回来」更清楚，
              // 且旁边的文字已经说明了原因。
              onChanged: canHide ? onToggle : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「设置页已隐藏」的提示卡：告诉用户怎么回来。
class _SettingsHiddenNotice extends StatelessWidget {
  const _SettingsHiddenNotice();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, size: 20, color: LumeTheme.info),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '「设置」页签已隐藏：底部导航里看不到它了。'
              '为了避免再也进不来本页，屏幕左下角会出现一个小的设置按钮，'
              '点它就能回到设置（以及本页）。',
              style: TextStyle(
                fontWeight: FontWeight.w400,
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「收起悬浮球」样式选项：左边一个真实可点的预览球，右边文案 + 选中勾。
class _HandleStyleOption extends StatelessWidget {
  const _HandleStyleOption({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final DockHandleStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = LumeTheme.accent;
    return Material(
      color: selected ? accent.withValues(alpha: .08) : LumeTheme.surfaceAlt,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('dock-handle-style-${style.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [accent.withValues(alpha: .22), LumeTheme.base],
                  ),
                ),
                child: Center(
                  child: DockHandleButton(
                    style: style,
                    size: 46,
                    onPressed: onTap,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      style.label,
                      style: TextStyle(
                        fontSize: LumeTypography.bodySize,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      style.description,
                      style: TextStyle(
                        fontSize: LumeTypography.descriptionSize,
                        color: LumeTheme.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 20,
                color: selected ? accent : LumeTheme.hairline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 管理页里的「迷你 Dock」：用真实参数画一颗胶囊。
///
/// 它只是外观预览（不是生产 Dock），但模糊、白度、边框、阴影、高度与左右留白
/// 都直接取当前设置值，调整滑块时能立刻看到玻璃透出的变化。
class _DockAppearancePreview extends StatelessWidget {
  const _DockAppearancePreview({required this.appearance, required this.style});

  final DockAppearance appearance;
  final FloatingStyle style;

  @override
  Widget build(BuildContext context) {
    final dark = LumeTheme.palette.brightness == Brightness.dark;
    // 预览卡比屏幕窄，留白按比例缩一点即可；不必精确还原 440pt 上的像素。
    final side = (8 + (appearance.horizontalMargin - 16) * .4)
        .clamp(8.0, 20.0)
        .toDouble();
    final borderAlpha =
        (dark ? appearance.borderOpacity * .44 : appearance.borderOpacity)
            .clamp(0.0, 1.0)
            .toDouble();
    final radius = BorderRadius.circular(appearance.height / 2);
    return ClipRRect(
      key: const ValueKey('dock-appearance-preview'),
      borderRadius: BorderRadius.circular(16),
      // Card 的 Column 用 start 对齐：显式给满宽，否则 Stack 在松约束下
      // 会按子项收缩，预览条可能只剩 0 宽（真机截图里就是一片空白）。
      child: SizedBox(
        width: double.infinity,
        height: 126,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const Row(
              // 必须 stretch：ColoredBox 没有子节点，交叉轴松约束下高度会是 0。
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: ColoredBox(color: Color(0xFF7C5CFF))),
                Expanded(child: ColoredBox(color: Color(0xFFFF7675))),
                Expanded(child: ColoredBox(color: Color(0xFF00B894))),
                Expanded(child: ColoredBox(color: Color(0xFF0984E3))),
                Expanded(child: ColoredBox(color: Color(0xFFFDCB6E))),
              ],
            ),
            Positioned(
              left: side,
              right: side,
              bottom: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: appearance.shadowOpacity,
                      ),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: style.blur,
                      sigmaY: style.blur,
                    ),
                    child: Container(
                      height: appearance.height,
                      decoration: BoxDecoration(
                        color: (dark ? LumeTheme.glass : Colors.white)
                            .withValues(alpha: style.opacity),
                        borderRadius: radius,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: borderAlpha),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: <Widget>[
                          _PreviewDockIcon(
                            Icons.menu_book_rounded,
                            selected: true,
                          ),
                          _PreviewDockIcon(Icons.auto_stories_outlined),
                          _PreviewDockIcon(Icons.play_circle_outline_rounded),
                          _PreviewDockIcon(Icons.pets_outlined),
                          _PreviewDockIcon(Icons.settings_outlined),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewDockIcon extends StatelessWidget {
  const _PreviewDockIcon(this.icon, {this.selected = false});

  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? LumeTheme.accent : LumeTheme.textSecondary;
    if (!selected) return Icon(icon, size: 16, color: color);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: LumeTheme.accent.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}
