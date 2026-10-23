import '../../shared/widgets/native_glass_controls.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock_bar.dart';
import '../shell/system_dock_bar.dart';
import 'settings_ui.dart';
import 'tab_bar_settings_page.dart';

class NativeNavigationSettingsPage extends StatelessWidget {
  const NativeNavigationSettingsPage({
    super.key,
    required this.controller,
    required this.entries,
  });

  final ShellSettingsController controller;
  final List<ShellDockEntry> entries;

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '原生系统导航',
    effectModule: GlassModule.settings,
    behindBar: true,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
        children: [
          NativeNavigationSettingsCard(
            controller: controller,
            entries: entries,
          ),
        ],
      ),
    ),
  );
}

class NativeNavigationSettingsCard extends StatefulWidget {
  const NativeNavigationSettingsCard({
    super.key,
    required this.controller,
    required this.entries,
  });

  final ShellSettingsController controller;
  final List<ShellDockEntry> entries;

  @override
  State<NativeNavigationSettingsCard> createState() =>
      _NativeNavigationSettingsCardState();
}

class _NativeNavigationSettingsCardState
    extends State<NativeNavigationSettingsCard> {
  late final _capabilities = SystemTabBarCapabilities.load();
  double? _previewHeight;
  String? _previewId;
  bool _previewAvailable = true;

  NativeNavigationSettings get settings =>
      widget.controller.settings.nativeNavigation;

  void _change(NativeNavigationSettings value, {bool save = true}) {
    widget.controller.updateNativeNavigation(value);
    if (save) unawaited(widget.controller.saveNativeNavigation());
  }

  @override
  Widget build(BuildContext context) => GlassCard(
    radius: 14,
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '原生系统导航',
          style: TextStyle(
            fontSize: LumeTypography.titleSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        NativeSwitchListTile.adaptive(
          key: const ValueKey('native-navigation-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('使用系统导航栏'),
          subtitle: const Text('开启使用完整系统栏；调节胶囊尺寸会切换为可调布局，仍保留原生玻璃材质。'),
          value: settings.enabled,
          onChanged: (value) => _change(settings.copyWith(enabled: value)),
        ),
        if (!settings.enabled) ...[
          const SettingsFooterNote('当前使用可调胶囊布局，下面展示实际底栏；开启系统栏后使用系统尺寸。'),
          DockAppearancePreview(
            appearance: widget.controller.appearance,
            entries: widget.entries,
            maxHeight: 200,
          ),
        ],
        if (settings.enabled) ...[
          FutureBuilder<SystemTabBarCapabilities>(
            future: _capabilities,
            builder: (context, snapshot) {
              final capabilities = snapshot.data;
              if (capabilities?.supported != true || !_previewAvailable) {
                return const SizedBox.shrink();
              }
              final height = _previewHeight ?? capabilities!.height;
              final id = widget.entries.any((e) => e.id == _previewId)
                  ? _previewId!
                  : widget.entries.any((e) => e.id == 'settings')
                  ? 'settings'
                  : widget.entries.first.id;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      colors: [
                        LumeTheme.accent.withValues(alpha: .15),
                        LumeTheme.base,
                      ],
                    ),
                  ),
                  child: MediaQuery.removeViewPadding(
                    context: context,
                    removeLeft: true,
                    removeRight: true,
                    removeBottom: true,
                    child: SystemDockBar(
                      entries: widget.entries,
                      activeId: id,
                      onSelect: (id) {
                        if (id != ShellDockEntry.search.id) {
                          setState(() => _previewId = id);
                        }
                      },
                      settings: settings,
                      height: height,
                      bottomMargin: 12 + settings.safeGap,
                      onHeightChanged: (value) {
                        if (mounted && value != _previewHeight) {
                          setState(() => _previewHeight = value);
                        }
                      },
                      onUnavailable: () {
                        if (mounted) setState(() => _previewAvailable = false);
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          NativeSwitchListTile.adaptive(
            key: const ValueKey('native-navigation-labels'),
            contentPadding: EdgeInsets.zero,
            title: const Text('显示标签文字'),
            value: settings.showLabels,
            onChanged: (value) => _change(settings.copyWith(showLabels: value)),
          ),
          NativeSwitchListTile.adaptive(
            key: const ValueKey('native-navigation-theme-tint'),
            contentPadding: EdgeInsets.zero,
            title: const Text('强调色跟随主题'),
            value: settings.followThemeColor,
            onChanged: (value) =>
                _change(settings.copyWith(followThemeColor: value)),
          ),
          if (!settings.followThemeColor)
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const {
                  0xFF7C5CFF: '紫色',
                  0xFF007AFF: '蓝色',
                  0xFF008A6A: '绿色',
                  0xFFE56A00: '橙色',
                  0xFFE83E72: '粉色',
                }.entries)
                  ChoiceChip(
                    key: ValueKey('native-navigation-color-${entry.key}'),
                    label: Text(entry.value),
                    avatar: Icon(
                      Icons.circle,
                      color: Color(entry.key),
                      size: 16,
                    ),
                    selected: settings.tintColor == entry.key,
                    onSelected: (_) =>
                        _change(settings.copyWith(tintColor: entry.key)),
                  ),
              ],
            ),
          _slider(
            'icon-size',
            '图标大小',
            settings.iconSize,
            18,
            30,
            (value) => settings.copyWith(iconSize: value),
          ),
          _slider(
            'margin',
            '左右留白',
            settings.horizontalMargin,
            0,
            40,
            (value) => settings.copyWith(horizontalMargin: value),
          ),
          _slider(
            'safe-gap',
            '安全区上方距离',
            settings.safeGap,
            0,
            32,
            (value) => settings.copyWith(safeGap: value),
          ),
          const SettingsFooterNote(
            '玻璃、选中动效和栏高由系统决定。图标最终尺寸由系统布局适配；'
            '“底栏尺寸与位置”使用可调胶囊布局；两种模式的预览分别与实际底栏使用同一组件。',
            padding: EdgeInsets.zero,
          ),
          TextButton(
            key: const ValueKey('native-navigation-reset'),
            onPressed: () => _change(const NativeNavigationSettings()),
            child: const Text('恢复原生导航默认参数'),
          ),
        ],
      ],
    ),
  );

  Widget _slider(
    String id,
    String label,
    double value,
    double min,
    double max,
    NativeNavigationSettings Function(double) update,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text('$label  ${value.round()}'),
      ),
      NativeGlassSlider(
        key: ValueKey('native-navigation-$id'),
        value: value,
        min: min,
        max: max,
        divisions: (max - min).round(),
        label: '${value.round()}',
        onChanged: (value) => _change(update(value), save: false),
        onChangeEnd: (_) => unawaited(widget.controller.saveNativeNavigation()),
      ),
    ],
  );
}
