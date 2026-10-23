import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock_bar.dart';
import 'native_navigation_settings_card.dart';
import 'icon_library_page.dart';
import 'settings_ui.dart';

List<ShellDockEntry> navigationPreviewEntries() => [
  const ShellDockEntry(
    id: 'comic',
    label: '漫画',
    icon: Icons.auto_stories_outlined,
    selectedIcon: Icons.auto_stories_rounded,
  ),
  const ShellDockEntry(
    id: 'video',
    label: '视频',
    icon: Icons.play_circle_outline_rounded,
    selectedIcon: Icons.play_circle_fill_rounded,
  ),
  const ShellDockEntry(
    id: 'settings',
    label: '设置',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
  ),
  ShellDockEntry.search,
];

class NavigationPreferencesPage extends StatelessWidget {
  const NavigationPreferencesPage({super.key});
  @override
  Widget build(BuildContext context) => NativeNavigationSettingsPage(
    controller: ShellSettingsController.instance,
    entries: navigationPreviewEntries(),
  );
}

class NavigationIconsPage extends StatelessWidget {
  const NavigationIconsPage({super.key});
  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '当前板块图标',
    effectModule: GlassModule.settings,
    behindBar: true,
    child: ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(20)),
      children: [
        const SettingsPageIntro(
          title: '导航图标',
          description: '分别设置未选中与选中状态，与全局图标库共用配置。',
        ),
        for (final entry in navigationPreviewEntries()) ...[
          SettingsGroupTitle(entry.label),
          for (final selected in [false, true])
            SettingsEntryCard(
              icon: selected ? entry.selectedIcon : entry.icon,
              title: '${entry.label} · ${selected ? '选中' : '未选中'}',
              subtitle: '替换图标或使用自己的图片',
              onTap: () => editAppIcon(
                context,
                'dock.${entry.id}.${selected ? 'selected' : 'normal'}',
                selected ? entry.selectedIcon : entry.icon,
              ),
            ),
        ],
      ],
    ),
  );
}
