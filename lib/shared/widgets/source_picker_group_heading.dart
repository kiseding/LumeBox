import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

/// Shared compact group heading inside the source card list's horizontal inset.
class SourcePickerGroupHeading extends StatelessWidget {
  const SourcePickerGroupHeading({
    super.key,
    required this.title,
    this.count,
    this.trailing,
  });

  static const double extent = 44;
  static const double listGap = 2;
  final String title;
  final int? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (count != null)
              Text(
                '$count',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            if (trailing != null)
              IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(36, 36),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                child: trailing!,
              ),
          ],
        ),
      ),
    ),
  );
}
