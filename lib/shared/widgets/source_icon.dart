import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

/// Website favicon where available; a stable monogram when it is unavailable.
class SourceIcon extends StatelessWidget {
  const SourceIcon({
    super.key,
    required this.name,
    this.siteUrl = '',
    this.iconUrl = '',
    this.siteIcon = '',
    this.size = 40,
  });
  final String name, siteUrl, iconUrl, siteIcon;
  final double size;
  @override
  Widget build(BuildContext context) {
    final origin = Uri.tryParse(siteUrl);
    final url = iconUrl.isNotEmpty
        ? iconUrl
        : siteIcon.isNotEmpty
        ? siteIcon
        : origin != null && origin.hasScheme && origin.host.isNotEmpty
        ? '${origin.origin}/favicon.ico'
        : '';
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: LumeTheme.accent.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Text(
          name.isEmpty ? '源' : name.characters.first,
          style: TextStyle(
            color: LumeTheme.accent,
            fontSize: size * .42,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: url.isEmpty
            ? fallback
            : Image.network(
                url,
                fit: BoxFit.contain,
                cacheWidth: 96,
                errorBuilder: (_, _, _) => fallback,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : fallback,
              ),
      ),
    );
  }
}
