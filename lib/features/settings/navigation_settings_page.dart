import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../shell/shell_dock_bar.dart';
import 'native_navigation_settings_card.dart';

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
