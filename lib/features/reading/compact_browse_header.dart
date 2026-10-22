import 'package:flutter/material.dart';

import '../shell/dock_search_button.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/shell/shell_settings.dart';
import '../../core/theme/floating_modules.dart';
import '../../shared/widgets/drawer_geometry.dart';
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

class BrowseSearchButton extends StatefulWidget {
  const BrowseSearchButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  State<BrowseSearchButton> createState() => _BrowseSearchButtonState();
}

class _BrowseSearchButtonState extends State<BrowseSearchButton> {
  ShellDockController? _registered;
  void _syncAction() {
    final scope = ShellDockScope.maybeScopeOf(context);
    final controller = scope?.searchInDock == true ? scope?.notifier : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_registered != controller) _registered?.unregisterSearch(this);
      _registered = controller;
      controller?.registerSearch(this, widget.onPressed);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAction();
  }

  @override
  void didUpdateWidget(BrowseSearchButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAction();
  }

  @override
  void dispose() {
    final controller = _registered;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller?.unregisterSearch(this),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ShellDockScope.maybeScopeOf(context);
    if (scope?.searchInDock == true) return const SizedBox.shrink();
    final beside = scope?.searchBesideDock == true;
    if (beside &&
        (scope?.notifier?.visible != true ||
            MediaQuery.viewInsetsOf(context).bottom > 0)) {
      return const SizedBox.shrink();
    }
    final appearance = ShellSettingsController.instance.appearance;
    final collapsed = beside && scope?.collapsed == true;
    final size = beside
        ? (collapsed
              ? (appearance.height * .82).clamp(40.0, 150.0)
              : appearance.searchButtonSize)
        : 52.0;
    final safe = scope?.safePadding ?? MediaQuery.viewPaddingOf(context);
    final margin = appearance.marginFor(
      MediaQuery.sizeOf(context).width - safe.horizontal,
      trailingWidth: appearance.searchWidth,
    );
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      right: beside ? (collapsed ? 8 : margin) + safe.right : 16,
      bottom: beside
          ? scope?.dockBottom ?? safe.bottom + appearance.safeGap
          : safe.bottom + 12,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: size),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => ListenableBuilder(
          listenable: FloatingModules.instance,
          builder: (context, _) => Transform.translate(
            offset: Offset(
              FloatingModules.instance.style(FloatingModule.dock).x,
              FloatingModules.instance.style(FloatingModule.dock).y,
            ),
            child: DockSearchButton(
              size: value,
              appearance: appearance,
              onPressed: widget.onPressed,
              beside: beside,
            ),
          ),
        ),
      ),
    );
  }
}
