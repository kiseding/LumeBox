import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/drawer_geometry.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/lume_icon.dart';
import '../shell/shell_dock.dart';
import 'browse_layout_button.dart';

/// One row for source selection and the two collection shortcuts.
class CompactBrowseHeader extends StatelessWidget {
  const CompactBrowseHeader({
    super.key,
    required this.source,
    required this.actions,
    required this.mode,
    required this.onLayoutChanged,
  });
  final Widget source;
  final List<Widget> actions;
  final BrowseLayoutMode mode;
  final ValueChanged<BrowseLayoutMode> onLayoutChanged;

  @override
  Widget build(BuildContext context) => DrawerSearchAnchor(
    child: Row(
      children: [
        Expanded(child: source),
        const SizedBox(width: 4),
        TextButtonTheme(
          data: TextButtonThemeData(
            style: TextButton.styleFrom(
              fixedSize: const Size(56, 44),
              minimumSize: const Size(56, 44),
              maximumSize: const Size(56, 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
        BrowseLayoutButton(
          mode: mode,
          onChanged: onLayoutChanged,
          quickSwitch: true,
        ),
      ],
    ),
  );
}

class BrowseSearchButton extends StatelessWidget {
  const BrowseSearchButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scope = ShellDockScope.maybeScopeOf(context);
    final beside = scope?.searchBesideDock == true;
    if (beside &&
        (scope?.notifier?.visible != true ||
            MediaQuery.viewInsetsOf(context).bottom > 0)) {
      return const SizedBox.shrink();
    }
    final appearance = ShellSettingsController.instance.appearance;
    final size = beside ? appearance.height : 52.0;
    final safe = scope?.safePadding ?? MediaQuery.viewPaddingOf(context);
    final margin = appearance.marginFor(
      MediaQuery.sizeOf(context).width - safe.horizontal,
      trailingWidth: size + 10,
    );
    return Positioned(
      right: beside ? margin + safe.right : 16,
      bottom: beside
          ? scope?.dockBottom ?? safe.bottom + appearance.safeGap
          : safe.bottom + 12,
      child: GlassPanel(
        key: const ValueKey('browse-search-surface'),
        module: beside ? FloatingModule.dock : null,
        radius: size / 2,
        child: IconButton(
          tooltip: '搜索',
          onPressed: onPressed,
          constraints: BoxConstraints.tightFor(width: size, height: size),
          icon: LumeIcon(
            Icons.search,
            slot: 'browse.floating.search',
            size: (size * .45).clamp(20, 40),
          ),
        ),
      ),
    );
  }
}
