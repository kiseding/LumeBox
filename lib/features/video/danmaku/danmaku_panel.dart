import '../../../shared/widgets/native_glass_surfaces.dart';
import '../../../shared/widgets/module_glass_scope.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/lume_theme.dart';

/// Landscape: a compact right drawer. Portrait: a bottom panel.
///
/// Uses a scroll-controlled modal sheet rather than a raw dialog so the whole
/// panel is laid out above the software keyboard. The previous dialog needed a
/// fixed percentage height; on iOS the keyboard could still cover the text
/// fields and the search button.
Future<T?> showDanmakuPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showGlassModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  constraints: const BoxConstraints(maxWidth: double.infinity),
  barrierColor: Colors.black.withValues(alpha: .22),
  builder: (context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: const SizedBox.expand(),
        ),
      ),
      DanmakuPanelFrame(child: builder(context)),
    ],
  ),
);

class DanmakuPanelFrame extends StatelessWidget {
  const DanmakuPanelFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.size.width > media.size.height;
    final keyboard = media.viewInsets.bottom;
    final textColor = LumeTheme.textPrimary;
    // Keep a hard guarantee: subtract the keyboard inset even on iOS versions
    // where the modal sheet route does not resize its child on its own.
    final available = math.max(
      0.0,
      media.size.height -
          media.viewPadding.top -
          media.viewPadding.bottom -
          keyboard -
          16,
    );
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.fromLTRB(
        media.viewPadding.left + 8,
        keyboard > 0 ? 8 : media.viewPadding.top + 8,
        media.viewPadding.right + 8,
        keyboard > 0 ? keyboard + 8 : math.max(media.viewPadding.bottom, 8.0),
      ),
      child: Align(
        alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
        child: SizedBox(
          key: const ValueKey('danmaku-panel-frame'),
          width: landscape ? media.size.width / 3 : 560,
          height: landscape
              ? math.min(available, media.size.height * .85)
              : available * .92,
          child: ModuleGlassScope(
            module: GlassModule.video,
            part: GlassPart.panels,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: MediaQuery.removeViewInsets(
                context: context,
                removeBottom: true,
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      textTheme: Theme.of(context).textTheme
                          .apply(bodyColor: textColor, displayColor: textColor),
                      iconTheme: IconThemeData(color: textColor),
                      inputDecorationTheme: Theme.of(context)
                          .inputDecorationTheme
                          .copyWith(
                            labelStyle: TextStyle(
                              color: LumeTheme.textSecondary,
                            ),
                            floatingLabelStyle: TextStyle(
                              color: LumeTheme.accent,
                            ),
                          ),
                    ),
                    child: DefaultTextStyle(
                      style: TextStyle(color: textColor, fontSize: 14),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
