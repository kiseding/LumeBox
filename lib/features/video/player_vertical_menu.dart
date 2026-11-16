import 'package:flutter/material.dart';

import '../../shared/widgets/video_glass_surface.dart';

abstract final class PlayerVerticalMenu {
  static const width = 128.0;
  static MenuStyle get style => MenuStyle(
    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static Widget body({
    required BuildContext context,
    required Key key,
    required List<Widget> children,
    double menuWidth = width,
  }) => VideoGlassSurface(
    radius: 12,
    dark: Theme.of(context).brightness == Brightness.dark,
    materialOpacity: VideoGlassSurface.panelOpacity,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        key: key,
        width: menuWidth,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    ),
  );

  static Widget option({
    required BuildContext context,
    required String label,
    required bool selected,
    required ValueChanged<bool>? onSelected,
    bool highlightSelection = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: SizedBox(
      height: highlightSelection ? 36 : null,
      child: ChoiceChip(
        label: SizedBox(
          width: double.infinity,
          child: highlightSelection
              ? Row(
                  children: [
                    Expanded(child: Text(label)),
                    SizedBox(
                      width: 14,
                      child: selected
                          ? Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                    ),
                  ],
                )
              : Text(label, textAlign: TextAlign.center),
        ),
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: highlightSelection && selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface,
        ),
        visualDensity: VisualDensity.compact,
        selected: selected,
        showCheckmark: !highlightSelection,
        color: WidgetStatePropertyAll(
          highlightSelection && selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .13)
              : Colors.transparent,
        ),
        padding: highlightSelection
            ? const EdgeInsets.symmetric(horizontal: 6)
            : null,
        backgroundColor: Colors.transparent,
        selectedColor: Colors.transparent,
        disabledColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        pressElevation: 0,
        checkmarkColor: Theme.of(context).colorScheme.onSurface,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(highlightSelection ? 9 : 6),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: onSelected,
      ),
    ),
  );
}
