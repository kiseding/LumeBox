import 'package:flutter/material.dart';

class HomeBrowseNavigation extends StatelessWidget {
  const HomeBrowseNavigation({
    super.key,
    required this.selected,
    required this.onSelect,
  });
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final mode in ['热门', '最新'])
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(36, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            backgroundColor: selected == mode
                ? Theme.of(context).colorScheme.primary.withValues(alpha: .12)
                : null,
            foregroundColor: selected == mode
                ? null
                : Theme.of(context).colorScheme.onSurface,
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          onPressed: () => onSelect(mode),
          child: Text(mode),
        ),
    ],
  );
}
