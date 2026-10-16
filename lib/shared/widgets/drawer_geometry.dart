import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Shared expanded height for classification, favorites and history drawers.
class DrawerGeometry {
  static double height(BuildContext context) {
    final media = MediaQuery.of(context);
    return math.min(
      media.size.height * .92,
      math.max(
        0,
        media.size.height - media.viewInsets.bottom - media.padding.top,
      ),
    );
  }
}
