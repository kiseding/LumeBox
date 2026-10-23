import 'danmaku/danmaku_panel.dart';

import 'package:flutter/material.dart';

import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/module_glass_scope.dart';

// Compatibility wrapper for existing routes; playback effects have been removed.
class PlaybackGlass extends StatelessWidget {
  const PlaybackGlass({
    super.key,
    required this.enabled,
    required this.child,
    this.dark = false,
  });
  final bool enabled, dark;
  final Widget child;
  @override
  Widget build(BuildContext context) => enabled
      ? ModuleGlassScope(
          module: GlassModule.video,
          part: GlassPart.panels,
          child: FrostedGlassWidget(
            part: GlassPart.panels,
            color: dark ? const Color(0xFF171721) : null,
            child: child,
          ),
        )
      : child;
}

Future<T?> showPlaybackMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool glass,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
}) => showDanmakuPanel<T>(context: context, builder: builder);
