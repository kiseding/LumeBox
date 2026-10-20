import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
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
    final dock = ShellDockScope.bottomInset(context);
    return Positioned(
      right: 16,
      bottom: (dock > 0 ? dock : MediaQuery.viewPaddingOf(context).bottom) + 12,
      child: GlassPanel(
        radius: 28,
        child: IconButton(
          tooltip: '搜索',
          onPressed: onPressed,
          constraints: const BoxConstraints.tightFor(width: 52, height: 52),
          icon: const LumeIcon(
            Icons.search,
            slot: 'browse.floating.search',
            size: 24,
          ),
        ),
      ),
    );
  }
}
