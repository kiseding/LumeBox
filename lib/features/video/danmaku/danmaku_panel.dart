import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/lume_theme.dart';

/// Landscape: a compact right drawer. Portrait: a bottom panel.
/// This route owns keyboard/safe-area avoidance for all danmaku screens.
Future<T?> showDanmakuPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '返回播放',
  barrierColor: Colors.black.withValues(alpha: .22),
  transitionDuration: const Duration(milliseconds: 200),
  pageBuilder: (context, _, _) => DanmakuPanelFrame(child: builder(context)),
  transitionBuilder: (context, animation, _, child) => SlideTransition(
    position: Tween<Offset>(
      begin:
          MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height
          ? const Offset(1, 0)
          : const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: child,
  ),
);

class DanmakuPanelFrame extends StatelessWidget {
  const DanmakuPanelFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.size.width > media.size.height;
    final textColor = LumeTheme.textPrimary;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.fromLTRB(
        media.viewPadding.left + 8,
        media.viewPadding.top + 8,
        media.viewPadding.right + 8,
        math.max(media.viewPadding.bottom, media.viewInsets.bottom) + 8,
      ),
      child: Align(
        alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
        child: LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            key: const ValueKey('danmaku-panel-frame'),
            width: landscape ? math.min(400, media.size.width * .46) : 560,
            // 键盘弹出时 AnimatedPadding 已经把可用高度压小；这里跟随可用
            // 约束而不是用屏幕高度的百分比，否则输入框会被键盘盖住。
            height: landscape ? double.infinity : constraints.maxHeight * .92,
            child: Material(
              color: LumeTheme.base,
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
