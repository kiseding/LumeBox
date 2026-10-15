import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Only installed inside playback routes. No global theme or non-player blur changes.
class PlaybackGlass extends StatelessWidget {
  const PlaybackGlass({
    super.key,
    required this.enabled,
    required this.child,
    this.dark = false,
  });
  final bool enabled;
  final bool dark;
  final Widget child;
  static Future<bool>? _androidSupport;
  static Future<bool> androidSupport() => _androidSupport ??= () async {
    try {
      return await const MethodChannel('lumebox/playback_effects')
              .invokeMethod<bool>('supportsBlur') ??
          false;
    } catch (_) {
      return false;
    }
  }();
  Widget flutterBlur() => BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0x33000000) : const Color(0x33FFFFFF),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: defaultTargetPlatform == TargetPlatform.iOS
                  ? UiKitView(
                      viewType: 'lumebox/playback_blur',
                      creationParams: {'dark': dark},
                      creationParamsCodec: const StandardMessageCodec(),
                    )
                  : defaultTargetPlatform == TargetPlatform.android
                  ? FutureBuilder<bool>(
                      future: androidSupport(),
                      builder: (context, result) => result.data == true
                          ? flutterBlur()
                          : const DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0x66000000),
                              ),
                            ),
                    )
                  : flutterBlur(),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

Future<T?> showPlaybackMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool glass,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
}) => showModalBottomSheet<T>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: isScrollControlled,
  useSafeArea: useSafeArea,
  builder: (context) => PlaybackGlass(enabled: glass, child: builder(context)),
);
