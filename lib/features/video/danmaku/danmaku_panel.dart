import '../../../shared/widgets/native_glass_surfaces.dart';
import '../../../shared/widgets/video_glass_surface.dart';
import '../../../shared/widgets/module_glass_scope.dart';

import 'dart:math' as math;

import '../player_layout.dart';

import 'package:flutter/material.dart';

/// Landscape: a compact right drawer. Portrait: a bottom panel.
///
/// Uses a scroll-controlled modal sheet rather than a raw dialog so the whole
/// panel is laid out above the software keyboard. The previous dialog needed a
/// fixed percentage height; on iOS the keyboard could still cover the text
/// fields and the search button.
Future<T?> showDanmakuPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  // 路由的 SafeArea 会移除子树中的横向 inset，先保留屏幕安全边距。
  final screenPadding = MediaQuery.viewPaddingOf(context);
  return showGlassModalBottomSheet<T>(
    context: context,
    videoGlass: false,
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
        DanmakuPanelFrame(
          screenPadding: screenPadding,
          child: builder(context),
        ),
      ],
    ),
  );
}

class DanmakuPanelFrame extends StatefulWidget {
  const DanmakuPanelFrame({super.key, required this.child, this.screenPadding});
  final Widget child;
  final EdgeInsets? screenPadding;
  @override
  State<DanmakuPanelFrame> createState() => _DanmakuPanelFrameState();
}

class _DanmakuPanelFrameState extends State<DanmakuPanelFrame> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.size.width > media.size.height;
    final keyboard = media.viewInsets.bottom;
    final safe = widget.screenPadding ?? media.viewPadding;
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
      duration: PlayerLayout.motion(context, 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.fromLTRB(
        math.max(media.viewPadding.left, safe.left) + 8,
        keyboard > 0 ? 8 : media.viewPadding.top + 8,
        math.max(media.viewPadding.right, safe.right) + (landscape ? 24 : 8),
        keyboard > 0 ? keyboard + 8 : math.max(media.viewPadding.bottom, 8.0),
      ),
      child: Align(
        alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
        child: SizedBox(
          key: const ValueKey('danmaku-panel-frame'),
          width: landscape
              ? PlayerLayout.panelWidth(media.size.width - safe.horizontal - 32)
              : 560,
          height: landscape
              ? math.min(available, media.size.height * .85)
              : available * (_expanded || keyboard > 0 ? .85 : .60),
          child: ModuleGlassScope(
            module: GlassModule.video,
            part: GlassPart.panels,
            child: VideoGlassSurface(
              radius: 24,
              dark: Theme.of(context).brightness == Brightness.dark,
              materialOpacity: .78,
              child: MediaQuery.removeViewInsets(
                context: context,
                removeBottom: true,
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  child: Column(
                    children: [
                      if (!landscape)
                        GestureDetector(
                          onVerticalDragEnd: (details) => setState(
                            () =>
                                _expanded = (details.primaryVelocity ?? 0) < 0,
                          ),
                          child: SizedBox(
                            height: 44,
                            child: Center(
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                tooltip: _expanded ? '收起面板' : '展开面板',
                                onPressed: () =>
                                    setState(() => _expanded = !_expanded),
                                icon: Icon(
                                  _expanded
                                      ? Icons.keyboard_arrow_down
                                      : Icons.keyboard_arrow_up,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Expanded(child: widget.child),
                    ],
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
