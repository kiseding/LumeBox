import '../../../shared/widgets/frosted_glass_widget.dart';
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
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: .22),
  builder: (context) => DanmakuPanelFrame(child: builder(context)),
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
      220.0,
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
          width: landscape ? math.min(400, media.size.width * .46) : 560,
          height: available * .92,
          child: ModuleGlassScope(
            module: GlassModule.video,
            part: GlassPart.panels,
            child: FrostedGlassWidget(
              radius: 20,
              part: GlassPart.panels,
              child: Material(
                color: Colors.transparent,
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
                        textTheme: Theme.of(context).textTheme.apply(
                          bodyColor: textColor,
                          displayColor: textColor,
                        ),
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
      ),
    );
  }
}
