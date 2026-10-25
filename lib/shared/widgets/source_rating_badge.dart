import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

class SourceRatingBadge extends StatelessWidget {
  const SourceRatingBadge({super.key, this.compact = false});

  /// 跟在版本号后面的主题色分级徽章，不单独占一行。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const message = '含成人内容 · 18+';
    final accent = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: message,
      child: Semantics(
        label: message,
        image: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .08),
            border: Border.all(color: accent.withValues(alpha: .22), width: .7),
            borderRadius: BorderRadius.circular(5),
          ),
          child: LumeIcon(
            Icons.eighteen_up_rating_outlined,
            slot: 'source_rating_badge.1',
            size: compact ? 16 : 20,
            color: accent,
          ),
        ),
      ),
    );
  }
}
