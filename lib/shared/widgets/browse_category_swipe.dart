import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Interior horizontal drags change categories without claiming drawer edges.
class BrowseCategorySwipe extends StatefulWidget {
  const BrowseCategorySwipe({
    super.key,
    required this.enabled,
    required this.onStep,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<int> onStep;
  final Widget child;

  @override
  State<BrowseCategorySwipe> createState() => _BrowseCategorySwipeState();
}

class _BrowseCategorySwipeState extends State<BrowseCategorySwipe> {
  double _travel = 0;

  bool _acceptStart(PointerEvent event) {
    if (!widget.enabled) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final x = box.globalToLocal(event.position).dx;
    final edges = MediaQuery.systemGestureInsetsOf(context);
    return x > edges.left + 32 && x < box.size.width - edges.right - 32;
  }

  void _finish(DragEndDetails details) {
    final travel = _travel;
    _travel = 0;
    if (widget.enabled && travel.abs() >= 64) {
      widget.onStep(travel < 0 ? 1 : -1);
    }
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      _CategorySwipeRecognizer:
          GestureRecognizerFactoryWithHandlers<_CategorySwipeRecognizer>(
            () => _CategorySwipeRecognizer(),
            (recognizer) {
              recognizer.acceptStart = _acceptStart;
              recognizer.onStart = (_) => _travel = 0;
              recognizer.onUpdate = (details) =>
                  _travel += details.primaryDelta ?? 0;
              recognizer.onEnd = _finish;
              recognizer.onCancel = () => _travel = 0;
            },
          ),
    },
    child: widget.child,
  );
}

class _CategorySwipeRecognizer extends HorizontalDragGestureRecognizer {
  bool Function(PointerEvent)? acceptStart;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (acceptStart?.call(event) ?? false) && super.isPointerAllowed(event);
}
